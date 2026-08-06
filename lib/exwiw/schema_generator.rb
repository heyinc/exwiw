# frozen_string_literal: true

require "fileutils"
require "json"

module Exwiw
  class SchemaGenerator
    # Summary of what `SchemaGenerator#tidy!` removed, returned so callers can
    # report it. `removed_columns` maps a surviving table's name to the column
    # names that were dropped from its config.
    class TidyResult
      attr_reader :removed_tables, :removed_columns

      def initialize
        @removed_tables = []
        @removed_columns = {}
      end

      def add_removed_table(table_name)
        @removed_tables << table_name
      end

      def add_removed_column(table_name, column_name)
        (@removed_columns[table_name] ||= []) << column_name
      end

      def empty?
        @removed_tables.empty? && @removed_columns.empty?
      end
    end

    # ActiveStorage tracks generated image variants in this table. Its rows are
    # derivative and regenerable — ActiveStorage lazily (re)creates a variant the
    # next time it is requested — so there is little value in exporting them. More
    # importantly, the table has no belongs_to path to any dump target, which
    # would land it in QueryAstBuilder's "no relation -> dump all" branch, while
    # its `blob_id` references active_storage_blobs, which the reverse
    # "referenced_by" extraction narrows to only the attachment-referenced blobs.
    # A full variant_records dump can therefore reference blobs that were never
    # exported (a foreign-key violation on import). So the table is emitted with
    # `ignore: true` (data extraction skipped) and excluded as a polymorphic
    # `record` target so the non-ignored attachments table carries no dangling
    # belongs_to to it.
    ACTIVE_STORAGE_VARIANT_RECORDS_TABLE = "active_storage_variant_records"

    def self.from_rails_application(output_dir:, safe_new_columns: false)
      Rails.application.eager_load!
      new(models: ActiveRecord::Base.descendants, output_dir: output_dir, safe_new_columns: safe_new_columns)
    end

    # `safe_new_columns` turns on safe mode: every column is emitted masked (as
    # far as its type allows, see DefaultMask) and flagged
    # `needs_mask_decision: true`. Only columns the config does not have yet keep
    # that treatment — #merge lets an existing entry win — so in practice it
    # applies to columns a migration has just added, which would otherwise be
    # exported unmasked without anyone looking at them.
    def initialize(models:, output_dir:, safe_new_columns: false)
      @models = models
      @output_dir = output_dir
      @safe_new_columns = safe_new_columns
    end

    def generate!
      groups = build_table_groups
      write_groups(groups)
      groups
    end

    # Flatten the generated `groups` (the Hash returned by generate! /
    # build_table_groups) into the list of cross-database belongs_tos the
    # generator auto-ignored, so a caller (the rake task) can surface them. Each
    # entry is `{ table:, foreign_key:, target: }`. Empty for single-database apps.
    def self.cross_database_belongs_tos(groups)
      groups.values.flatten.flat_map do |table|
        next [] unless table.respond_to?(:belongs_tos)

        table.belongs_tos
             .select { |bt| bt.ignore_type == CROSS_DATABASE_IGNORE_TYPE }
             .map { |bt| { table: table.name, foreign_key: bt.foreign_key, target: bt.table_name } }
      end
    end

    # Reconcile the config files already on disk against the live database,
    # removing only what no longer exists there:
    #
    # - a config file whose table is no longer present is deleted, and
    # - columns recorded in a surviving table's config that the table no
    #   longer has are dropped from that file.
    #
    # The source of truth is the database connection (`data_sources` for table
    # existence — which covers views too — and `columns` for the column list),
    # NOT `build_table_groups`. `build_table_groups` only knows about tables
    # that still have an ActiveRecord model, so reconciling against it would
    # delete the config of a table that is still present in the database but
    # has merely lost (or never had) a model. Reading the connection directly
    # avoids that: only a table that is genuinely gone from the database is
    # removed.
    #
    # Unlike `generate!`, tidy never adds or regenerates entries: every
    # surviving table/column — including its hand-edited `comment` / `ignore` /
    # `replace_with` — is left untouched, and only the stale entries are
    # stripped. (Removing a deleted column is something `generate!` already does
    # incidentally via #merge, but `generate!` can never delete the config file
    # of a removed table, which is the gap this fills.) Returns a TidyResult
    # describing the removals so callers (e.g. the rake task) can report them.
    def tidy!
      result = TidyResult.new

      model_db_groups.each do |db_name, _group_models, conn|
        dir = config_dir_for(db_name)
        next unless Dir.exist?(dir)

        existing_data_sources = conn.data_sources.to_set

        Dir[File.join(dir, "*.json")].sort.each do |path|
          existing = TableConfig.from(JSON.parse(File.read(path)))

          unless existing_data_sources.include?(existing.name)
            File.delete(path)
            result.add_removed_table(existing.name)
            next
          end

          valid_column_names = conn.columns(existing.name).map(&:name).to_set
          stale_columns = existing.columns.reject { |column| valid_column_names.include?(column.name) }
          next if stale_columns.empty?

          existing.columns = existing.columns.select { |column| valid_column_names.include?(column.name) }
          File.write(path, JSON.pretty_generate(existing.to_hash) + "\n")
          stale_columns.each { |column| result.add_removed_column(existing.name, column.name) }
        end
      end

      result
    end

    # Returns a Hash keyed by the database name.
    #
    # - Single-database setup: the only key is `nil`, signalling that the table
    #   configs should be written flat into `output_dir` (backwards compatible).
    # - Multi-database setup (Rails `connects_to`): one key per database
    #   (`connection_db_config.name`, e.g. "primary" / "analytics"), each
    #   mapping to that database's table configs. They are written into
    #   `output_dir/<db_name>/`.
    def build_table_groups
      model_db_groups.each_with_object({}) do |(db_name, group_models, conn), result|
        result[db_name] = build_tables_for(group_models, conn)
      end
    end

    # The per-database grouping that both `build_table_groups` and `tidy!` work
    # from: `[[db_name, models, connection], ...]`.
    #
    # - Single-database setup: one entry keyed by `nil` (configs written flat
    #   into `output_dir`). When there are no models at all, fall back to the
    #   default connection so callers still have a connection to inspect.
    # - Multi-database setup (Rails `connects_to`): one entry per database,
    #   keyed by `connection_db_config.name` ("primary" / "analytics", ...).
    #
    # The db_name <-> connection mapping is necessarily model-derived: which
    # databases the app talks to is only declared on the model side (via
    # `connects_to`). What each consumer reads *through* that connection differs
    # — `build_table_groups` builds configs from the models, while `tidy!`
    # reads the live database's actual tables/columns.
    private def model_db_groups
      models = concrete_models
      grouped = models.group_by { |model| database_name_for(model) }

      if grouped.size <= 1
        conn = models.empty? ? ActiveRecord::Base.connection : models.first.connection
        return [[nil, models, conn]]
      end

      grouped.map { |db_name, group_models| [db_name, group_models, group_models.first.connection] }
    end

    # Backwards-compatible flat list of all table configs. Only meaningful for
    # a single-database setup; for multi-database setups prefer
    # `#build_table_groups` so the database association is preserved.
    def build_tables
      build_table_groups.values.flatten
    end

    def write_groups(groups)
      groups.each do |db_name, tables|
        write_files(config_dir_for(db_name), tables)
      end
    end

    # The directory a database group's config files live in. A single-database
    # setup (`db_name` is nil) writes flat into `output_dir`; a multi-database
    # setup writes into `output_dir/<db_name>/`. Shared by `write_groups` and
    # `tidy!` so the two operations agree on file locations.
    private def config_dir_for(db_name)
      db_name.nil? ? @output_dir : File.join(@output_dir, db_name)
    end

    def write_files(dir, tables)
      FileUtils.mkdir_p(dir)

      tables.each do |table|
        path = File.join(dir, "#{table.name}.json")
        config_to_write =
          if File.exist?(path)
            TableConfig.from(JSON.parse(File.read(path))).merge(table)
          else
            table
          end
        File.write(path, JSON.pretty_generate(config_to_write.to_hash) + "\n")
      end
    end

    private def build_tables_for(models, conn)
      tables_from_models = models.group_by(&:table_name).map do |table_name, model_group|
        representative = model_group.first
        primary_key = representative.primary_key

        # Tables with a composite primary key (`representative.primary_key` is an
        # Array) are not supported yet. Emit them with `primary_key` omitted,
        # `ignore: true`, and a `type` that marks them as unsupported — the `type`
        # acts as a signpost for adding support later. The config file itself is
        # still generated so a user can manually remove `ignore` and wire it up
        # when needed.
        if primary_key.is_a?(Array)
          TableConfig.from_symbol_keys(
            name: table_name,
            type: TableConfig::UNSUPPORTED_COMPOSITE_PRIMARY_KEY,
            ignore: true,
            comment: "exwiw does not support composite primary keys " \
                     "(#{primary_key.join(', ')}); data extraction is skipped.",
            belongs_tos: aggregate_belongs_tos(model_group),
            columns: representative.column_names.map { |name| { name: name } },
          )
        elsif table_name == ACTIVE_STORAGE_VARIANT_RECORDS_TABLE
          # See ACTIVE_STORAGE_VARIANT_RECORDS_TABLE. Emitted with ignore:true so
          # the derivative variant rows are not dumped; primary_key/columns are
          # kept so a user can remove `ignore` to opt back in if they really want
          # to export them.
          TableConfig.from_symbol_keys(
            name: table_name,
            primary_key: primary_key,
            ignore: true,
            comment: "ActiveStorage variant tracking records are derivative and " \
                     "regenerable; data extraction is skipped. Remove `ignore` to export them.",
            belongs_tos: aggregate_belongs_tos(model_group),
            columns: representative.column_names.map { |name| { name: name } },
          )
        else
          belongs_tos = aggregate_belongs_tos(model_group)
          TableConfig.from_symbol_keys(
            name: table_name,
            primary_key: primary_key,
            belongs_tos: belongs_tos,
            columns: build_columns(representative, primary_key, belongs_tos, conn),
          )
        end
      end

      tables_from_models + build_rails_managed_tables(conn)
    end

    # The `columns` entries for a table. Outside safe mode (and for the ignored
    # tables, which are never extracted) a column is just its name.
    #
    # In safe mode each column also gets a default mask and the
    # `needs_mask_decision` flag. The keys that hold the export together —
    # the primary key and the foreign keys/types the belongs_tos join on — are
    # flagged but never masked: masking them would break the joins and leave the
    # dump with dangling references.
    private def build_columns(representative, primary_key, belongs_tos, conn)
      names = representative.column_names
      return names.map { |name| { name: name } } unless @safe_new_columns

      structural = belongs_tos.flat_map { |bt| [bt[:foreign_key], bt[:foreign_type]] }.compact.to_set
      structural << primary_key if primary_key
      columns_by_name = representative.columns.each_with_object({}) { |column, acc| acc[column.name] = column }
      unique = unique_column_names(conn, representative.table_name)

      names.map do |name|
        entry = { name: name, needs_mask_decision: true }
        next entry if structural.include?(name)

        column = columns_by_name[name]
        mask = column && DefaultMask.for(
          name: name,
          type: column.type,
          limit: column.limit,
          primary_key: primary_key,
          # An array column reports its member type (`integer[]` is `:integer`),
          # so a scalar default would be rejected by the column on restore.
          array: column.respond_to?(:array?) && column.array?,
          unique: unique.include?(name),
        )
        mask.nil? ? entry : entry.merge(replace_with: mask)
      end
    end

    # Columns covered by a unique index, which a constant mask would collapse
    # onto one value. An expression index yields no plain column name, so it
    # simply never matches.
    private def unique_column_names(conn, table_name)
      conn.indexes(table_name).select(&:unique).flat_map { |index| Array(index.columns) }.to_set
    rescue StandardError
      Set.new
    end

    private def concrete_models
      @models.reject(&:abstract_class?).select(&:table_exists?)
    end

    # The rails-managed tables (`schema_migrations` / `ar_internal_metadata`)
    # have no model class, so they cannot be picked up from
    # `ActiveRecord::Base.descendants`. In a multi-DB setup each connection has
    # its own migration history table, so we take the target connection and only
    # emit an entry when the table actually exists on that connection. The table
    # name itself (including any prefix/suffix) comes from the global settings
    # (`ActiveRecord::Base.schema_migrations_table_name`, etc.).
    private def build_rails_managed_tables(conn)
      result = []

      schema_migrations_name = ActiveRecord::Base.schema_migrations_table_name
      if conn.table_exists?(schema_migrations_name)
        result << TableConfig.from_symbol_keys(
          name: schema_migrations_name,
          type: TableConfig::RAILS_MANAGED_SCHEMA_MIGRATIONS,
          comment: "Managed internally by Rails. Tracks applied schema migrations.",
          belongs_tos: [],
          columns: [],
        )
      end

      internal_metadata_name = ActiveRecord::Base.internal_metadata_table_name
      if conn.table_exists?(internal_metadata_name)
        result << TableConfig.from_symbol_keys(
          name: internal_metadata_name,
          type: TableConfig::RAILS_MANAGED_INTERNAL_METADATA,
          comment: "Managed internally by Rails. Stores environment and schema metadata.",
          belongs_tos: [],
          columns: [],
        )
      end

      result
    end

    private def aggregate_belongs_tos(models)
      belongs_to_assocs = models
        .flat_map { |m| belongs_to_associations_for(m) }
        .select { |assoc| assoc.polymorphic? || active_record_target?(assoc) }
      owner_db = database_name_for(models.first)

      non_polymorphic = belongs_to_assocs
        .reject(&:polymorphic?)
        .map do |assoc|
          entry = { table_name: assoc.table_name, foreign_key: assoc.foreign_key }
          annotate_cross_database(entry, owner_db, assoc.klass)
        end

      # A polymorphic belongs_to (`belongs_to :reviewable, polymorphic: true`)
      # has no single target table. The candidate tables are found by looking up
      # the other models that declare `has_many/has_one ..., as: <association_name>`.
      # For each candidate table, expand one belongs_to entry carrying the type
      # column (`foreign_type`) and the stored type value (`type_value`).
      polymorphic = belongs_to_assocs
        .select(&:polymorphic?)
        .flat_map do |assoc|
          polymorphic_target_models(assoc.name).map do |target_model|
            entry = {
              table_name: target_model.table_name,
              foreign_key: assoc.foreign_key,
              foreign_type: assoc.foreign_type,
              type_value: target_model.polymorphic_name,
            }
            annotate_cross_database(entry, owner_db, target_model)
          end
        end

      (non_polymorphic + polymorphic).uniq
    end

    CROSS_DATABASE_IGNORE_TYPE = "cross_database"

    # A belongs_to whose target model lives in a *different* database than the
    # owning table cannot be joined: in a Rails multi-database (`connects_to`)
    # setup each database is exported on its own connection and into its own
    # per-database config directory, so the target table is absent from the
    # directory this config is loaded with, and there is no single connection to
    # join the two on. Leaving the relation live would emit a dangling belongs_to
    # whose target is never present at extraction time (a nil-target crash in
    # dependency resolution). So emit it with `ignore: true` (dropped from
    # extraction at load via TableConfig#reject_ignored_members!) tagged
    # `ignore_type: "cross_database"`, with a `comment` recording why and pointing
    # at the recovery path. The foreign-key column itself is still exported as a
    # plain column; only the join/dependency edge is dropped. Polymorphic
    # associations are annotated per target, so only the targets that cross a
    # database boundary are ignored. Single-database apps are unaffected.
    private def annotate_cross_database(entry, owner_db, target_model)
      target_db = database_name_for(target_model)
      return entry if target_db == owner_db

      entry.merge(
        ignore: true,
        ignore_type: CROSS_DATABASE_IGNORE_TYPE,
        comment: "Cross-database belongs_to: target '#{entry[:table_name]}' is in database " \
                 "'#{target_db}', not '#{owner_db}'. exwiw exports each database separately and " \
                 "cannot join across them, so this relation is ignored during extraction; its " \
                 "foreign-key column '#{entry[:foreign_key]}' is still exported. To extract across " \
                 "this boundary, declare `scope_column: \"#{entry[:foreign_key]}\"` on this table's " \
                 "config so its rows are filtered by that foreign-key value directly (scope-column mode).",
      )
    end

    # `belongs_to` reflections for a model, with the synthetic HABTM left-side
    # association removed.
    #
    # Rails backs every `has_and_belongs_to_many` with an anonymous join model
    # (`HABTM_*`, a concrete `ActiveRecord::Base` descendant whose table is the
    # join table). That join model declares two belongs_tos: the "right side"
    # (named after the association, e.g. `belongs_to :tags` -> `tag_id`), which
    # is correct, and a synthetic `belongs_to :left_side`. The left-side
    # association is built with `anonymous_class:` and no `foreign_key:`, so AR
    # derives its foreign key from the reflection name -> `left_side_id`, a
    # column that does not exist in the join table. Dropping it leaves the join
    # table with only its genuine foreign keys; the right-side reflections of
    # the two HABTM_* models together still supply both (`post_id` + `tag_id`).
    private def belongs_to_associations_for(model)
      assocs = model.reflect_on_all_associations(:belongs_to)
      return assocs unless model.respond_to?(:left_reflection)

      left = model.left_reflection
      assocs.reject { |assoc| assoc.equal?(left) }
    end

    # Whether a (non-polymorphic) belongs_to points at an ActiveRecord model.
    #
    # A belongs_to can target a non-ActiveRecord class — most commonly an
    # ActiveHash/ActiveYaml master (`belongs_to :equipment, class_name:
    # "SomeActiveYamlModel"`). active_hash registers these as ordinary
    # `belongs_to` reflections, yet the target class has no database table, so
    # `assoc.table_name` (which delegates to `klass.table_name`) raises. Such a
    # relation is not a DB edge exwiw can join or extract across, so it is
    # dropped from the generated belongs_tos; the underlying foreign-key column
    # is still emitted as a plain column. Polymorphic associations cannot be
    # `klass`-resolved, so callers must screen those out before calling this.
    #
    # Resolving the target class behaves differently per non-AR shape: an
    # ActiveHash reflection returns the class fine (the crash is later, at
    # `table_name`), while a bare `belongs_to` to a plain class makes AR raise
    # ArgumentError ("... is not an ActiveRecord::Base subclass") right here when
    # the klass is computed. Both mean "not a DB relation", so rescue the lookup
    # and treat either as a non-AR target to skip.
    private def active_record_target?(assoc)
      klass = assoc.klass
      klass.is_a?(Class) && klass < ActiveRecord::Base ? true : false
    rescue StandardError
      false
    end

    # Enumerate the concrete models that can be targets of the polymorphic
    # association `association_name`, by looking them up from every model's
    # `has_many` / `has_one` `as:` option. The order of `concrete_models` depends
    # on `ActiveRecord::Base.descendants`, which can vary by Ruby version, so sort
    # by `table_name` to return a deterministic order and keep the generated
    # belongs_to ordering stable.
    private def polymorphic_target_models(association_name)
      concrete_models.select do |model|
        # active_storage_variant_records is ignored (see the constant), so it must
        # not be expanded as a polymorphic target — otherwise the non-ignored
        # attachments table would carry a dangling belongs_to to an ignored table,
        # which is rejected at load time.
        next false if model.table_name == ACTIVE_STORAGE_VARIANT_RECORDS_TABLE

        (model.reflect_on_all_associations(:has_many) +
         model.reflect_on_all_associations(:has_one))
          .any? { |reflection| reflection.options[:as] == association_name }
      end.sort_by(&:table_name)
    end

    # Identifies which database a model belongs to. With Rails multi-DB
    # (`connects_to` backed by `database.yml`), `connection_db_config.name`
    # returns the configuration name ("primary", "analytics", ...) which is
    # stable across roles/shards and makes a natural per-database directory
    # name. Single-database apps all share one name, collapsing into one group.
    private def database_name_for(model)
      model.connection_db_config.name
    end
  end
end
