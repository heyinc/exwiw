# frozen_string_literal: true

require "fileutils"
require "json"
require "set"

module Exwiw
  # Generates (and tidies) a schema config from a live database connection
  # instead of from an application's models — see DbIntrospector for why an
  # application exwiw cannot load needs this.
  #
  # It mirrors SchemaGenerator table for table and column for column, with one
  # deliberate difference in how belongs_tos are reconciled (see
  # #merged_belongs_tos) and one structural simplification: the output directory
  # is flat, because a connection addresses exactly one database. A second
  # database is a second run against a second connection, which is also how the
  # extraction itself treats it.
  class DbSchemaGenerator
    # SchemaGenerator::TidyResult plus the belongs_tos this generator can also
    # remove. Subclassed rather than extended in place so the ActiveRecord
    # generator's result — and the rake task reporting it — keeps exactly the
    # contract it has today.
    class TidyResult < SchemaGenerator::TidyResult
      attr_reader :removed_belongs_tos

      def initialize
        super
        @removed_belongs_tos = {}
      end

      def add_removed_belongs_to(table_name, target_table_name)
        (@removed_belongs_tos[table_name] ||= []) << target_table_name
      end

      def empty?
        super && @removed_belongs_tos.empty?
      end
    end

    # `safe_new_columns` matches SchemaGenerator's: on (the default) every
    # column is emitted masked as far as its type allows and flagged
    # `needs_mask_decision: true`, and #merge lets an already-decided entry win,
    # so in practice only genuinely new columns keep that treatment.
    def initialize(introspector:, output_dir:, safe_new_columns: true)
      @introspector = introspector
      @output_dir = output_dir
      @safe_new_columns = safe_new_columns
    end

    # Write one config file per table in the database, merged with whatever is
    # already on disk, and return the configs as written.
    #
    # Unlike SchemaGenerator, the configs are built *inside* the write path
    # rather than by a separate builder: what the generated belongs_tos are —
    # and therefore which columns count as structural and must not be masked —
    # depends on the existing file (see #merged_belongs_tos), so the two cannot
    # be separated without introspecting the disk twice.
    def generate!
      FileUtils.mkdir_p(@output_dir)

      @introspector.table_names.map do |table_name|
        path = File.join(@output_dir, "#{table_name}.json")
        existing = read_config(path)
        generated = build_table(table_name, existing)

        config_to_write = existing ? existing.merge(generated) : generated
        File.write(path, JSON.pretty_generate(config_to_write.to_hash) + "\n")
        config_to_write
      end
    end

    # Reconcile the config files on disk against the database, removing only
    # what no longer exists there:
    #
    # - a config file whose table is gone is deleted,
    # - columns a surviving table no longer has are dropped, and
    # - a belongs_to pointing at a table that is gone is dropped.
    #
    # The belongs_to case is this generator's own. Because #generate! only ever
    # adds relations (never rewrites the list), a relation whose target table
    # was dropped would otherwise survive every regeneration, and a belongs_to
    # with no target table crashes dependency resolution at extraction time.
    # An `ignore: true` entry is kept regardless: those are user tombstones
    # recording a decision ("this relation is deliberately not extracted"), and
    # deleting one would invite the next regeneration to add the edge back.
    #
    # Like SchemaGenerator#tidy!, nothing is added or regenerated here: every
    # surviving entry keeps its hand-edited `comment` / `ignore` /
    # `replace_with` untouched. Returns a TidyResult describing the removals.
    def tidy!
      result = TidyResult.new
      return result unless Dir.exist?(@output_dir)

      # Views are not generated (see DbIntrospector::Base#table_names), so a
      # config naming one is stale by the same definition as a dropped table.
      existing_tables = @introspector.table_names.to_set

      Dir[File.join(@output_dir, "*.json")].sort.each do |path|
        existing = TableConfig.from(JSON.parse(File.read(path)))

        unless existing_tables.include?(existing.name)
          File.delete(path)
          result.add_removed_table(existing.name)
          next
        end

        changed = false
        changed |= remove_stale_columns(existing, result)
        changed |= remove_dangling_belongs_tos(existing, existing_tables, result)
        File.write(path, JSON.pretty_generate(existing.to_hash) + "\n") if changed
      end

      result
    end

    private def read_config(path)
      return nil unless File.exist?(path)

      TableConfig.from(JSON.parse(File.read(path)))
    end

    # The config for one table, in the same three shapes SchemaGenerator emits
    # — with one more case it has to handle: a table with no primary key at
    # all. ActiveRecord always reports one (a model without it cannot be
    # queried), but a database is free to have none.
    private def build_table(table_name, existing)
      introspected_primary_key = @introspector.primary_key(table_name)
      primary_key = declared_primary_key(introspected_primary_key, existing)
      belongs_tos = merged_belongs_tos(table_name, existing)
      column_names = @introspector.columns(table_name).map(&:name)

      # A composite primary key is not supported yet. The config file is still
      # generated — with `primary_key` omitted, `ignore: true` and a `type`
      # marking it unsupported — so it can serve as a signpost for adding
      # support later, and so a user can wire it up by hand meanwhile.
      if primary_key.nil? && introspected_primary_key.is_a?(Array)
        TableConfig.from_symbol_keys(
          name: table_name,
          type: TableConfig::UNSUPPORTED_COMPOSITE_PRIMARY_KEY,
          ignore: true,
          comment: "exwiw does not support composite primary keys " \
                   "(#{introspected_primary_key.join(', ')}); data extraction is skipped.",
          belongs_tos: belongs_tos,
          columns: column_names.map { |name| { name: name } },
        )
      elsif primary_key.nil?
        # exwiw addresses rows by primary key — it is what an extraction query
        # filters and joins on — so a table without one cannot be extracted as
        # it stands. Emitted with `ignore: true` rather than skipped entirely so
        # the table is visible in the config (and in schema:check) instead of
        # silently missing, and so opting it in is an edit rather than a
        # discovery.
        TableConfig.from_symbol_keys(
          name: table_name,
          ignore: true,
          comment: "This table has no primary key, which exwiw needs to identify and join rows; " \
                   "data extraction is skipped. To export it, set `primary_key` to a column that " \
                   "uniquely identifies a row and remove `ignore`.",
          belongs_tos: belongs_tos,
          columns: column_names.map { |name| { name: name } },
        )
      else
        TableConfig.from_symbol_keys(
          name: table_name,
          primary_key: primary_key,
          belongs_tos: belongs_tos,
          columns: build_columns(table_name, primary_key, belongs_tos),
        )
      end
    end

    # The primary key to build a table's config from: the one the database
    # reports, or — when it reports none exwiw can use — the one the config on
    # disk declares.
    #
    # The fallback is what makes the two signpost shapes below actionable. Both
    # tell the user to name a primary key by hand ("set `primary_key` to a
    # column that uniquely identifies a row and remove `ignore`"), and a table
    # can be perfectly extractable that way — a natural key with a unique index
    # but no PK constraint, or one column of a composite key that is unique on
    # its own. Without this, following those instructions would not survive the
    # next run: `TableConfig#merge` takes `primary_key` from the generated side,
    # which is still nil because the database is unchanged, so the hand-set key
    # would be dropped and the table left with nothing to join or filter on —
    # silently, since the regenerated config is also what `schema check`
    # compares against.
    #
    # A declared key also selects the ordinary table shape, so the `type` /
    # `comment` signposts are not re-imposed on a table the user has since wired
    # up (`ignore` is receiver-owned in the merge and already stays removed).
    private def declared_primary_key(introspected_primary_key, existing)
      return introspected_primary_key if introspected_primary_key.is_a?(String)

      declared = existing&.primary_key
      declared.is_a?(String) ? declared : nil
    end

    # The belongs_tos to generate for a table: everything the existing config
    # already declares, verbatim and in its on-disk order, plus the
    # foreign-key-derived relations it does not have yet, appended in sorted
    # order.
    #
    # This union is the one place this generator deliberately departs from the
    # ActiveRecord one, and it exists because a foreign-key constraint is
    # strictly weaker evidence than an application model. Plenty of schemas
    # express a relation only in application code — no constraint backs it —
    # and the belongs_tos in an existing config are frequently hand-written for
    # exactly that reason. They are load-bearing: a belongs_to is the path
    # extraction follows to reach a table, so dropping one silently narrows the
    # dump. TableConfig#merge rebuilds `belongs_tos` from the generated side,
    # which is safe when that side saw the models and knows the full set, but
    # would delete every unbacked relation here.
    #
    # So introspection only ever *adds* an edge. Removing one is tidy's job,
    # where it is driven by the target table actually being gone rather than by
    # the absence of a constraint (see #tidy!).
    # Returns plain hashes rather than BelongsTo objects, because that is what
    # TableConfig.from_symbol_keys consumes (it round-trips the whole table
    # through JSON) — and because a hash of the existing entry carries its
    # user-owned `comment` / `ignore` / `ignore_type` / `references` along
    # without this method having to know they exist.
    private def merged_belongs_tos(table_name, existing)
      declared = (existing&.belongs_tos || []).map(&:to_hash)
      # Identity here is the physical join — target table plus foreign-key
      # column — rather than BelongsTo#identity, which also distinguishes the
      # polymorphic type value. A hand-written polymorphic relation already
      # covers its foreign-key column, so re-adding the bare constraint edge
      # would emit a second belongs_to joining on the same column.
      declared_keys = declared.map { |entry| [entry["table_name"], entry["foreign_key"]] }.to_set

      discovered = @introspector.foreign_keys(table_name)
        .reject { |entry| declared_keys.include?([entry[:table_name], entry[:foreign_key]]) }
        .map { |entry| { "table_name" => entry[:table_name], "foreign_key" => entry[:foreign_key] } }

      declared + discovered
    end

    # The `columns` entries for a table: just the name, or — in safe mode — also
    # a default mask and the `needs_mask_decision` flag, exactly as
    # SchemaGenerator#build_columns does it. The primary key and the foreign
    # keys/types the belongs_tos join on are flagged but never masked, since
    # masking them would break the joins.
    #
    # The structural set is computed from the *merged* belongs_tos, so a
    # relation that exists only in the config — with no constraint behind it —
    # protects its foreign-key column from a default mask just as a discovered
    # one does. An `ignore: true` relation counts too: the column is still a
    # foreign key, and the tombstone says nothing about masking it.
    private def build_columns(table_name, primary_key, belongs_tos)
      columns = @introspector.columns(table_name)
      return columns.map { |column| { name: column.name } } unless @safe_new_columns

      structural = belongs_tos.flat_map { |bt| [bt["foreign_key"], bt["foreign_type"]] }.compact.to_set
      structural << primary_key
      unique = @introspector.unique_column_names(table_name)

      columns.map do |column|
        entry = { name: column.name, needs_mask_decision: true }
        next entry if structural.include?(column.name)

        mask = DefaultMask.for(
          name: column.name,
          type: column.type,
          limit: column.limit,
          primary_key: primary_key,
          array: column.array,
          unique: unique.nil? || unique.include?(column.name),
          column_default: column.default,
        )
        mask.nil? ? entry : entry.merge(replace_with: mask)
      end
    end

    private def remove_stale_columns(existing, result)
      valid_column_names = @introspector.columns(existing.name).map(&:name).to_set
      stale = existing.columns.reject { |column| valid_column_names.include?(column.name) }
      return false if stale.empty?

      existing.columns = existing.columns.select { |column| valid_column_names.include?(column.name) }
      stale.each { |column| result.add_removed_column(existing.name, column.name) }
      true
    end

    private def remove_dangling_belongs_tos(existing, existing_tables, result)
      dangling = existing.belongs_tos.reject do |belongs_to|
        # An ignored relation is a user tombstone and is kept whatever its
        # target is; one with no target at all is already inert (it records a
        # relation exwiw cannot resolve) and is left alone as well.
        belongs_to.ignore || belongs_to.table_name.nil? || existing_tables.include?(belongs_to.table_name)
      end
      return false if dangling.empty?

      existing.belongs_tos = existing.belongs_tos - dangling
      dangling.each { |belongs_to| result.add_removed_belongs_to(existing.name, belongs_to.table_name) }
      true
    end
  end
end
