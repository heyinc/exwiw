# frozen_string_literal: true

module Exwiw
  class TableConfig
    include Serdes

    RAILS_MANAGED_SCHEMA_MIGRATIONS = "rails_managed_schema_migrations"
    RAILS_MANAGED_INTERNAL_METADATA = "rails_managed_internal_metadata"
    RAILS_MANAGED_TYPES = [
      RAILS_MANAGED_SCHEMA_MIGRATIONS,
      RAILS_MANAGED_INTERNAL_METADATA,
    ].freeze

    # type marking a table with a composite primary key, which exwiw does not
    # support yet. schema:generate attaches it together with ignore:true. Unlike
    # rails-managed tables, columns/belongs_tos are retained so it can serve as a
    # signpost for adding support later.
    UNSUPPORTED_COMPOSITE_PRIMARY_KEY = "unsupported_composite_primary_key"

    attribute :name, String
    attribute :primary_key, optional(String), skip_serializing_if_nil: true
    attribute :type, optional(String), skip_serializing_if_nil: true
    attribute :comment, optional(String), skip_serializing_if_nil: true
    attribute :filter, optional(String), skip_serializing_if_nil: true
    attribute :belongs_tos, array(BelongsTo), default: []
    attribute :columns, array(TableColumn), default: []
    attribute :bulk_insert_chunk_size, optional(Integer), skip_serializing_if_nil: true
    attribute :ignore, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true
    # Scope-column mode only (see Exwiw::DumpTarget#scope_column). Both are
    # user-configured and never emitted by the schema generators.
    #
    # `scope_exempt: true` exports the whole table without scope filtering — the
    # explicit, auditable escape hatch for genuine reference/master tables under
    # the strict "every table must be scopable" rule.
    #
    # `scope_column` overrides the physical column this table is filtered on when
    # it differs from the global `--scope-column` name (same scope value, just a
    # different column name on this table).
    attribute :scope_exempt, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true
    attribute :scope_column, optional(String), skip_serializing_if_nil: true

    # `reverse_scope` opts a table into multi-referencer reverse scoping (see
    # Exwiw::ReverseScope and QueryAstBuilder#build_referenced_by_clause): a
    # global-identity table (e.g. `users`) referenced by many scoped tables is
    # constrained to the UNION of those referencers' projected foreign keys
    # instead of being dumped in full. User-configured and never emitted by the
    # schema generators.
    attribute :reverse_scope, Serdes::OptionalType.new(ReverseScope), skip_serializing_if_nil: true

    def self.from(hash)
      config = super
      config.send(:validate_after_load!)
      config
    end

    def self.from_symbol_keys(hash)
      from(JSON.parse(hash.to_json))
    end

    def rails_managed?
      RAILS_MANAGED_TYPES.include?(type)
    end

    def to_hash
      hash = super
      if rails_managed?
        hash.delete("belongs_tos")
        hash.delete("columns")
        hash.delete("reverse_scope")
      end
      hash
    end

    def column_names
      columns.map(&:name)
    end

    # Drop the belongs_tos/columns flagged `ignore:true` so they are excluded
    # from extraction (dependency ordering, SELECT projection, INSERT). The
    # config files on disk keep these entries; this is applied to the runtime
    # config right after it is loaded from a file (see Runner#load_table_config).
    def reject_ignored_members!
      self.belongs_tos = belongs_tos.reject(&:ignore)
      self.columns = columns.reject(&:ignore)

      # A table that will be extracted needs at least one effective column;
      # otherwise the generated SELECT (`SELECT  FROM ...`) and INSERT
      # (`INSERT INTO t () ...`) are syntactically broken. Checked here, after
      # rejection, so it catches both a genuinely empty `columns: []` and a list
      # left empty because every column was ignore:true. Schema generation does
      # not call this method, so regenerating a broken config still works.
      if !rails_managed? && !ignore && columns.empty?
        raise ArgumentError,
              "Table '#{name}' has no columns to extract " \
              "(it may be empty in the config or have all columns set to ignore:true); " \
              "define or unignore at least one column."
      end

      self
    end

    def belongs_to(table_name)
      belongs_tos.find { |relation| relation.table_name == table_name }
    end

    def build_extract_query(extract_target_table, extract_target_ids, tables_by_name)
      # target is itself
      if name == extract_target_table
        return [{
          from: name,
          where: [{ primary_key => extract_target_ids }],
          join: [],
          select: column_names,
        }]
      end

      # it is not related to target table
      if belongs_to.empty?
        return [{
          from: name,
          where: [],
          join: [],
          select: column_names,
        }]
      end

      belongs_to_extract_target_table = belongs_tos.find { |relation| relation.table_name == extract_target_table }
      if belongs_to_extract_target_table
        key = belongs_to_extract_target_table.foreign_key
        return [{ from: name, where: [{ key => extract_target_ids }], join: [], select: column_names }]
      end

      ret = compute_dependency_to_table(extract_target_table, tables_by_name)

      if ret.empty?
        [{
          from: name,
          where: [],
          join: [],
          select: column_names,
        }]
      else
        last = ret.last
        last[:where] = [{ last[:foreign_key] => extract_target_ids }]
        ret
      end
    end

    def merge(passed_table)
      return passed_table if passed_table.to_hash == self.to_hash


      TableConfig.new.tap do |merged_table|
        merged_table.name = name
        merged_table.primary_key = passed_table.primary_key
        merged_table.type = passed_table.type
        merged_table.comment = comment
        merged_table.filter = filter
        merged_table.bulk_insert_chunk_size = passed_table.bulk_insert_chunk_size
        merged_table.ignore = ignore
        # User-owned, never regenerated: carry over from the existing config.
        merged_table.scope_exempt = scope_exempt
        merged_table.scope_column = scope_column
        merged_table.reverse_scope = reverse_scope

        # Structural facts of each belongs_to come from the freshly generated
        # config, but the user-owned `comment`/`ignore`/`ignore_type`/`references`
        # carry over when the same relation still exists. (`references` is only
        # consumed by the MongodbAdapter, but it lives on the shared BelongsTo, so
        # preserve it here too rather than silently dropping a hand-added value.)
        receiver_belongs_to_by_identity = belongs_tos.each_with_object({}) { |bt, hash| hash[bt.identity] = bt }
        merged_table.belongs_tos =
          passed_table.belongs_tos.map do |passed_belongs_to|
            receiver_belongs_to = receiver_belongs_to_by_identity[passed_belongs_to.identity]
            if receiver_belongs_to
              passed_belongs_to.comment = receiver_belongs_to.comment if receiver_belongs_to.comment
              passed_belongs_to.ignore = receiver_belongs_to.ignore unless receiver_belongs_to.ignore.nil?
              passed_belongs_to.ignore_type = receiver_belongs_to.ignore_type if receiver_belongs_to.ignore_type
              passed_belongs_to.references = receiver_belongs_to.references if receiver_belongs_to.references
            end
            passed_belongs_to
          end

        receiver_column_by_name = columns.each_with_object({}) { |column, hash| hash[column.name] = column }

        merged_table.columns =
          passed_table.columns.map do |passed_column|
            if receiver_column_by_name.key?(passed_column.name)
              receiver_column = receiver_column_by_name[passed_column.name]
              receiver_column
            else
              passed_column
            end
          end
      end
    end

    private def validate_after_load!
      if rails_managed?
        if primary_key
          raise ArgumentError,
                "Table '#{name}' has type=#{type}; primary_key must not be defined."
        end
        if !belongs_tos.empty?
          raise ArgumentError,
                "Table '#{name}' has type=#{type}; belongs_tos must not be defined."
        end
        if !columns.empty?
          raise ArgumentError,
                "Table '#{name}' has type=#{type}; columns must not be defined."
        end
        if reverse_scope
          raise ArgumentError,
                "Table '#{name}' has type=#{type}; reverse_scope must not be defined."
        end
      else
        # An ignore:true table is not extracted, so primary_key is not required
        # (e.g. a composite-primary-key table that exwiw does not support).
        if primary_key.nil? && !ignore
          raise ArgumentError, "Table '#{name}' requires primary_key."
        end

        columns.each { |column| validate_ruby_side_masking!(column) }
      end
    end

    # The Ruby-side masking modes (`map` / `replace_with_fake_data`) are strictly
    # exclusive — with each other and with the SQL-side modes. Only the new keys
    # are restricted: the legacy raw_sql > replace_with precedence stays lenient.
    # Deliberately static (no faker require, no proc eval) so schema
    # regeneration never executes config Ruby; the seed column and the map proc
    # are resolved at dump time by RowTransformer.build.
    private def validate_ruby_side_masking!(column)
      ruby_side = [column.map && "map", column.replace_with_fake_data && "replace_with_fake_data"].compact
      return if ruby_side.empty?

      sql_side = [column.raw_sql && "raw_sql", column.replace_with && "replace_with"].compact
      if ruby_side.size > 1 || sql_side.any?
        raise ArgumentError,
              "Table '#{name}' column '#{column.name}': #{(ruby_side + sql_side).join('/')} cannot be combined; " \
              "use at most one of map/replace_with_fake_data, without raw_sql/replace_with."
      end

      fake_data = column.replace_with_fake_data
      return unless fake_data

      supported_types = RowTransformer::PERSON_TYPES.keys + RowTransformer::FAKE_TYPES.keys
      unless supported_types.include?(fake_data.type)
        raise ArgumentError,
              "Table '#{name}' column '#{column.name}': unknown replace_with_fake_data type '#{fake_data.type}' " \
              "(supported: #{supported_types.join(', ')})."
      end

      seed_column = fake_data.seed.delete_prefix("#{name}.")
      if seed_column.include?(".") || columns.none? { |c| c.name == seed_column }
        raise ArgumentError,
              "Table '#{name}' column '#{column.name}': replace_with_fake_data seed '#{fake_data.seed}' " \
              "does not name a column of this table (use 'column' or '#{name}.column')."
      end
    end

    private def compute_dependency_to_table(target_table_name, tables_by_name)
      return [] if belongs_tos.empty?

      results = belongs_tos.map do |relation|
        relation_table = tables_by_name[relation.table_name]

        if relation_table.name == target_table_name
          [{ base_table_name: name, foreign_key: relation.foreign_key,
             join_table_name: target_table_name, join_key: relation_table.primary_key }]
        else
          ret = relation_table.compute_dependency_to_table(target_table_name, tables_by_name)
          [{ base_table_name: name, foreign_key: relation.foreign_key,
             join_table_name: relation_table.name, join_key: relation_table.primary_key }] + ret
        end
      end.compact

      matched_dependencies = results.select do |dependency|
        dependency.last[:join_table_name] == target_table_name
      end

      return [] if matched_dependencies.empty?

      matched_dependencies.min_by(&:size)
    end
  end
end
