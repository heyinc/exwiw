# frozen_string_literal: true

namespace :exwiw do
  namespace :schema do
    # Output directory for the generated schema config. Precedence:
    #   1. EXWIW_SCHEMA_DIR_PATH env var (explicit per-run override)
    #   2. schema_dir in the exwiw config file (exwiw.yml/.yaml), so generating
    #      the schema and running the `exwiw` CLI agree on one location without
    #      repeating the path
    #   3. the historical "exwiw/schema" default
    # Resolved at task-run time (after `require "exwiw"` has loaded ConfigFile).
    resolve_schema_dir = lambda do
      ENV["EXWIW_SCHEMA_DIR_PATH"] || Exwiw::ConfigFile.schema_dir || "exwiw/schema"
    end

    # Safe mode (EXWIW_NEW_COLUMNS=safe): emit every column the config does not
    # have yet masked and flagged `needs_mask_decision: true`, so a column added
    # by a migration cannot reach a dump before someone decides how it should be
    # masked. Off by default — the generated config is unchanged without it.
    safe_new_columns = lambda { ENV["EXWIW_NEW_COLUMNS"] == "safe" }

    desc "Generate schema from application"
    task generate: :environment do
      require "exwiw"

      groups = Exwiw::SchemaGenerator.from_rails_application(
        output_dir: resolve_schema_dir.call,
        safe_new_columns: safe_new_columns.call,
      ).generate!

      # Surface cross-database belongs_tos the generator auto-ignored: these
      # cannot be joined (each database is exported separately), so they were
      # emitted with ignore:true and need a decision from the user.
      cross = Exwiw::SchemaGenerator.cross_database_belongs_tos(groups)
      unless cross.empty?
        $stderr.puts "exwiw: detected #{cross.size} cross-database belongs_to(s), " \
                     "each emitted with ignore:true (exwiw cannot join across databases). " \
                     "The foreign-key column is still exported."
        cross.each do |c|
          $stderr.puts "  - #{c[:table]}.#{c[:foreign_key]} -> #{c[:target]} (in another database)"
        end
        $stderr.puts "  To extract across a boundary, declare `scope_column: <foreign_key>` on the " \
                     "owning table's config (scope-column mode). Otherwise the relation stays ignored " \
                     "and the foreign key is exported as a plain value."
      end
    end

    desc "Remove tables/columns from the schema config that no longer exist in the application"
    task tidy: :environment do
      require "exwiw"

      result = Exwiw::SchemaGenerator.from_rails_application(
        output_dir: resolve_schema_dir.call,
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
        output_dir: resolve_schema_dir.call,
        skip_unsupported: ENV["EXWIW_SKIP_UNSUPPORTED"] == "1",
      ).generate!
    end
  end
end
