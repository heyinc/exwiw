# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "tmpdir"

module Exwiw
  # Reports how the committed schema config differs from what the application
  # would generate now, plus the columns still waiting for a masking decision.
  #
  # Regenerating into a copy of the config directory rather than over it means
  # the check can run on a working tree it must not modify (CI), and the
  # comparison covers exactly what `schema:generate` + `schema:tidy` would do:
  # tables and columns added by a migration, and entries whose table is gone.
  class SchemaCheck
    CATEGORIES = %w[
      added_tables added_columns removed_tables removed_columns changed_tables needs_mask_decision
    ].freeze

    def self.from_rails_application(schema_dir:)
      Rails.application.eager_load!
      new(models: ActiveRecord::Base.descendants, schema_dir: schema_dir)
    end

    def initialize(models:, schema_dir:)
      @models = models
      @schema_dir = schema_dir
    end

    # The report as a plain Hash, ready to serialize. Every list is sorted so a
    # given state always produces the same output (it ends up in a CI comment).
    def run
      committed = read_configs(@schema_dir)
      regenerated = Dir.mktmpdir do |tmp_dir|
        regenerate_into(tmp_dir)
        read_configs(tmp_dir)
      end

      report = diff(committed, regenerated)
      report["needs_mask_decision"] = flagged_columns(committed)
      report
    end

    # Whether the report requires someone to act: the config is out of date, or
    # a column's masking has not been decided yet.
    def self.clean?(report)
      CATEGORIES.all? { |category| report.fetch(category, []).empty? }
    end

    private def regenerate_into(tmp_dir)
      FileUtils.cp_r(File.join(@schema_dir, "."), tmp_dir) if Dir.exist?(@schema_dir)
      SchemaGenerator.new(models: @models, output_dir: tmp_dir, safe_new_columns: true).generate!
      SchemaGenerator.new(models: @models, output_dir: tmp_dir).tidy!
    end

    # Every config file under `dir`, keyed by its path relative to `dir` so the
    # per-database subdirectories of a multi-database app stay distinct.
    #
    # Hand-editing these files is the workflow this check exists to drive, so a
    # syntax error is a likely outcome and has to name the file it is in rather
    # than surfacing as a bare parse error from somewhere in the run.
    private def read_configs(dir)
      return {} unless Dir.exist?(dir)

      Dir[File.join(dir, "**", "*.json")].each_with_object({}) do |path, acc|
        key = Pathname.new(path).relative_path_from(Pathname.new(dir)).to_s
        begin
          acc[key] = JSON.parse(File.read(path))
        rescue JSON::ParserError => e
          raise JSON::ParserError, "invalid JSON in schema config '#{path}': #{e.message}"
        end
      end
    end

    private def diff(committed, regenerated)
      report = CATEGORIES.to_h { |category| [category, []] }

      (committed.keys | regenerated.keys).sort.each do |key|
        before = committed[key]
        after = regenerated[key]

        if before.nil?
          report["added_tables"] << table_label(key, after)
          next
        end
        if after.nil?
          report["removed_tables"] << table_label(key, before)
          next
        end
        next if before == after

        label = table_label(key, before)
        report["changed_tables"] << label
        added, removed = column_diff(before, after)
        report["added_columns"] += added.sort.map { |column| "#{label}.#{column}" }
        report["removed_columns"] += removed.sort.map { |column| "#{label}.#{column}" }
      end

      report
    end

    private def column_diff(before, after)
      before_names = column_names(before)
      after_names = column_names(after)
      [after_names - before_names, before_names - after_names]
    end

    # `fields` is the MongoDB config's spelling of `columns`.
    private def column_names(config)
      (config["columns"] || config["fields"] || []).map { |column| column["name"] }
    end

    # How a table is named in the report. A multi-database app keeps one
    # subdirectory per database and the same table name can appear in several of
    # them, so the database is part of the label — otherwise the entries collide
    # (every database has its own `schema_migrations`).
    private def table_label(key, config)
      name = config&.fetch("name", nil) || File.basename(key, ".json")
      db = File.dirname(key)
      db == "." ? name : "#{db}/#{name}"
    end

    private def flagged_columns(committed)
      committed.flat_map do |key, config|
        (config["columns"] || config["fields"] || [])
          .select { |column| column["needs_mask_decision"] }
          .map { |column| "#{table_label(key, config)}.#{column['name']}" }
      end.sort
    end
  end
end
