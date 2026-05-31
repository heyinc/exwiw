# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# Snapshot test for the dumped `insert-*.{sql,jsonl,js}` files. Runs Runner
# against the seeded DB for each adapter and diffs the generated output
# against fixtures under spec/insert_output_snapshots/<adapter>/.
#
# Re-generate the fixtures by running with `UPDATE_SNAPSHOTS=1`. The leading
# `insert-000-schema.*` is included; pg_dump output is normalised first to
# strip the run-specific `\restrict <nonce>` token and the local pg_dump
# version header, both of which would otherwise flake on every run.
module Exwiw
  RSpec.describe "insert output snapshots" do
    # Strip pg_dump preamble lines that are non-deterministic:
    #   - `\restrict <random-token>` / `\unrestrict <random-token>` (nonce changes per run)
    #   - `-- Dumped from database version X.Y` / `-- Dumped by pg_dump version X.Y`
    #     (depends on the local pg_dump binary)
    def self.normalise_pg_schema(content)
      content
        .gsub(/^\\(restrict|unrestrict) \S+$/) { "\\#{Regexp.last_match(1)} <NONCE>" }
        .gsub(/^-- Dumped (from database|by pg_dump) version .*$/) { "-- Dumped #{Regexp.last_match(1)} version <PGVER>" }
    end

    def self.normalise(adapter, basename, content)
      return normalise_pg_schema(content) if adapter == "postgresql" && basename == "insert-000-schema.sql"

      content
    end
    SCENARIOS = [
      {
        adapter: "sqlite",
        config_dir: "scenario/sqlite-schema",
        connection: {
          adapter: "sqlite",
          database_name: "tmp/test.sqlite3",
          host: nil, port: nil, user: nil, password: nil,
        },
      },
      {
        adapter: "mysql",
        config_dir: "scenario/mysql-schema",
        connection: {
          adapter: "mysql",
          database_name: "exwiw_test",
          host: "127.0.0.1", port: 3306,
          user: "root", password: "rootpassword",
        },
      },
      {
        adapter: "postgresql",
        config_dir: "scenario/postgresql-schema",
        connection: {
          adapter: "postgresql",
          database_name: "exwiw_test",
          host: "127.0.0.1", port: 5432,
          user: "postgres", password: "test_password",
        },
      },
      {
        adapter: "postgresql",
        config_dir: "scenario/postgresql-schema",
        output_format: "copy",
        snapshot_subdir: "postgresql-copy",
        connection: {
          adapter: "postgresql",
          database_name: "exwiw_test",
          host: "127.0.0.1", port: 5432,
          user: "postgres", password: "test_password",
        },
      },
      {
        adapter: "mongodb",
        config_dir: "scenario/mongodb-schema",
        # The mongo seed keys `_id` with a deterministic ObjectId: a 4-hex
        # per-collection tag (shops -> "a001") + the zero-padded integer. The
        # tag's letter keeps the id from being all-decimal, so the adapter
        # coerces this 24-char hex back to a BSON::ObjectId (not an Integer) for
        # the `$in` filter.
        ids: ["a00100000000000000000001"],
        connection: {
          adapter: "mongodb",
          database_name: "exwiw_test",
          host: ENV.fetch("MONGO_HOST", "127.0.0.1"),
          port: ENV.fetch("MONGO_PORT", 27017).to_i,
          user: nil, password: nil,
        },
      },
    ].freeze

    SCENARIOS.each do |scenario|
      context_suffix = scenario[:output_format] ? " (#{scenario[:output_format]})" : ""
      context "with #{scenario[:adapter]} adapter#{context_suffix}" do
        let(:output_dir) { @output_dir }
        let(:snapshot_dir) { File.join("spec/insert_output_snapshots", scenario[:snapshot_subdir] || scenario[:adapter]) }
        let(:connection_config) { ConnectionConfig.new(**scenario[:connection]) }
        let(:runner) do
          Runner.new(
            connection_config: connection_config,
            output_dir: output_dir,
            config_dir: scenario[:config_dir],
            dump_target: DumpTarget.new(table_name: "shops", ids: scenario.fetch(:ids, ["1"])),
            output_format: scenario.fetch(:output_format, "insert"),
            logger: ::Logger.new(nil),
          )
        end

        around do |ex|
          Dir.mktmpdir do |dir|
            @output_dir = dir
            ex.run
          end
        end

        it "matches insert-* snapshots" do
          runner.run

          actual_paths = Dir[File.join(output_dir, "insert-*")].sort

          if ENV["UPDATE_SNAPSHOTS"]
            FileUtils.mkdir_p(snapshot_dir)
            FileUtils.rm_f(Dir[File.join(snapshot_dir, "insert-*")])
            actual_paths.each do |p|
              normalised = self.class.normalise(scenario[:adapter], File.basename(p), File.read(p))
              File.write(File.join(snapshot_dir, File.basename(p)), normalised)
            end
            skip "snapshots regenerated for #{scenario[:adapter]} (#{actual_paths.size} files)"
          end

          snapshot_paths = Dir[File.join(snapshot_dir, "insert-*")].sort
          expect(snapshot_paths).not_to be_empty,
            "no snapshots under #{snapshot_dir}. regenerate with UPDATE_SNAPSHOTS=1"

          expect(actual_paths.map { |p| File.basename(p) })
            .to eq(snapshot_paths.map { |p| File.basename(p) })

          snapshot_paths.each do |snapshot_path|
            basename = File.basename(snapshot_path)
            actual_content = self.class.normalise(scenario[:adapter], basename, File.read(File.join(output_dir, basename)))
            expect(actual_content).to eq(File.read(snapshot_path)),
              "snapshot mismatch in #{basename} (#{scenario[:adapter]})"
          end
        end
      end
    end
  end
end
