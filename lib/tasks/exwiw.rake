# frozen_string_literal: true

namespace :exwiw do
  namespace :schema do
    # Resolve where the generators write their config. Precedence, highest first:
    #   1. EXWIW_SCHEMA_DIR_PATH (explicit per-invocation override; kept for
    #      backward compatibility with existing callers),
    #   2. `schema_dir` in the project's exwiw.yml/exwiw.yaml — so generation
    #      lands exactly where `exwiw export`/`explain` later read from, instead
    #      of relying on a second hard-coded default, and
    #   3. the historical "exwiw/schema" default.
    # EXWIW_CONFIG may point at a non-default config file path (mirrors --config).
    def exwiw_schema_output_dir
      env = ENV["EXWIW_SCHEMA_DIR_PATH"]
      return env if env && !env.empty?

      config = Exwiw::ConfigFile.find(path: ENV["EXWIW_CONFIG"])
      config&.schema_dir || "exwiw/schema"
    end

    desc "Generate schema from application"
    task generate: :environment do
      require "exwiw"

      Exwiw::SchemaGenerator.from_rails_application(
        output_dir: exwiw_schema_output_dir,
      ).generate!
    end

    desc "Remove tables/columns from the schema config that no longer exist in the application"
    task tidy: :environment do
      require "exwiw"

      result = Exwiw::SchemaGenerator.from_rails_application(
        output_dir: exwiw_schema_output_dir,
      ).tidy!

      if result.empty?
        puts "exwiw: schema config is already tidy; nothing to remove."
      else
        result.removed_tables.each do |name|
          puts "exwiw: removed config for table '#{name}' (no longer exists in the application)."
        end
        result.removed_columns.each do |table_name, columns|
          puts "exwiw: removed column(s) #{columns.join(', ')} from '#{table_name}' (no longer in the table)."
        end
      end
    end

    desc "Generate schema from a Mongoid application"
    # Fail-loud by default: the task aborts on a construct exwiw cannot represent
    # (an unresolvable `belongs_to`, or a polymorphic / cyclic / ambiguous /
    # unresolvable `embedded_in`). To keep a deliberately-unrepresentable
    # collection or relation from aborting the run, mark it `ignore: true` in its
    # config on disk (optionally with an `ignore_type` / `comment` recording why);
    # the generator honors that and skips re-introspecting it. Set
    # EXWIW_SKIP_UNSUPPORTED=1 to additionally keep going past *un-annotated*
    # unrepresentable constructs (the unresolvable belongs_to is skipped and an
    # unrepresentable embedded collection is emitted as `ignore: true` with a
    # `comment`, each warned to stderr) — useful for the first bootstrap pass
    # against a large app before the ignores are written.
    task generate_mongoid: :environment do
      require "exwiw"

      Exwiw::MongoidSchemaGenerator.from_rails_application(
        output_dir: exwiw_schema_output_dir,
        skip_unsupported: ENV["EXWIW_SKIP_UNSUPPORTED"] == "1",
      ).generate!
    end
  end
end
