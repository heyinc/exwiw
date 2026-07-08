# frozen_string_literal: true

require 'erb'

module Exwiw
  class AfterInsertHook
    def self.run(path:, cli_options:, output_dir:, next_idx:, output_extension:, logger:)
      ext = File.extname(path)

      if ext == '.rb'
        run_ruby(
          path: path,
          cli_options: cli_options,
          output_dir: output_dir,
          next_idx: next_idx,
          output_extension: output_extension,
          logger: logger,
        )
      else
        run_shell(path: path, cli_options: cli_options, output_dir: output_dir, logger: logger)
      end
    end

    def self.run_ruby(path:, cli_options:, output_dir:, next_idx:, output_extension:, logger:)
      ctx = Context.new(cli_options, output_extension: output_extension)
      ctx.instance_eval(File.read(path), path)

      # One output file per buffer, numbered sequentially from next_idx: first
      # the shared collection-less buffer (kept at next_idx so existing hooks
      # produce the same filename as before), then one file per targeted
      # collection in first-targeted order. Collection files reuse the
      # insert-NNN-<collection>.{ext} naming of the per-table dump files, so
      # filename-driven import tooling handles them unchanged.
      outputs = []
      content = ctx.collected.join("\n")
      outputs << ['after_insert', content] unless content.empty?
      ctx.collected_by_collection.each do |collection, chunks|
        body = chunks.join("\n")
        next if body.empty?
        outputs << [collection, body]
      end

      if outputs.empty?
        logger.info("After-insert hook produced no output; skipping file write.")
        return
      end

      outputs.each_with_index do |(name, body), offset|
        idx_str = (next_idx + offset).to_s.rjust(3, '0')
        output_path = File.join(output_dir, "insert-#{idx_str}-#{name}.#{output_extension}")
        File.write(output_path, body)
        logger.info("Wrote after-insert hook output to #{output_path}")
      end
    end

    def self.run_shell(path:, cli_options:, output_dir:, logger:)
      env = {
        'EXWIW_OUTPUT_DIR'       => output_dir,
        'EXWIW_SCHEMA_DIR'       => cli_options[:schema_dir].to_s,
        'EXWIW_DATABASE_ADAPTER' => cli_options[:database_adapter].to_s,
        'EXWIW_DATABASE_HOST'    => cli_options[:database_host].to_s,
        'EXWIW_DATABASE_PORT'    => cli_options[:database_port].to_s,
        'EXWIW_DATABASE_USER'    => cli_options[:database_user].to_s,
        'EXWIW_DATABASE_NAME'    => cli_options[:database_name].to_s,
        'EXWIW_TARGET_TABLE'     => cli_options[:target_table].to_s,
        'EXWIW_SCOPE_COLUMN'     => cli_options[:scope_column].to_s,
        'EXWIW_IDS'              => Array(cli_options[:ids]).join(','),
        'EXWIW_OUTPUT_FORMAT'    => cli_options[:output_format].to_s,
      }
      logger.info("Running after-insert shell hook: #{path}")
      ok = system(env, path)
      raise "after-insert shell hook failed: #{path}" unless ok
    end

    class Context
      # Collection names become part of the output filename, so restrict them
      # to plain path-safe names (no separators, no leading dot).
COLLECTION_NAME_PATTERN = /\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/

      attr_reader :cli_options, :collected, :collected_by_collection

      def initialize(cli_options, output_extension: nil)
        @cli_options = cli_options
        @output_extension = output_extension
        @collected = []
        @collected_by_collection = {}
      end

      def insert_sql(template)
        @collected << render(template)
      end

      # With one argument, identical to insert_sql: the rendered output goes to
      # the shared collection-less buffer (insert-NNN-after_insert.{ext}).
      #
      # With two arguments (MongoDB adapter only), the rendered output is
      # appended to the named collection's own buffer and written to
      # insert-NNN-<collection>.jsonl. SQL statements name their table in-band,
      # but JSONL documents do not — the import convention derives the target
      # collection from the filename — so this is the only way a hook can seed
      # documents into a specific collection.
      def insert_jsonl(collection_or_template, template = nil)
        return insert_sql(collection_or_template) if template.nil?

        unless @output_extension == 'jsonl'
          raise ArgumentError,
                "insert_jsonl(collection, template) is only supported for the MongoDB adapter; " \
                "SQL statements already name their table, use insert_sql(template) instead."
        end

        collection = collection_or_template.to_s
        unless collection.match?(COLLECTION_NAME_PATTERN)
          raise ArgumentError, "invalid collection name for insert_jsonl: #{collection_or_template.inspect}"
        end

        (@collected_by_collection[collection] ||= []) << render(template)
      end

      private def render(template)
        ERB.new(template, trim_mode: '-').result(binding)
      end
    end
  end
end
