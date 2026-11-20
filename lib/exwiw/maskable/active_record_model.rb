# frozen_string_literal: true

module Exwiw
  module Maskable
    # Adds `mask_with_exwiw!` to an ActiveRecord model and its relations. Rows are read and updated through the
    # model's connection, so inside the caller's transaction when one is open; it opens none of its own. Updates
    # bypass callbacks.
    #
    #   class ApplicationRecord < ActiveRecord::Base
    #     include Exwiw::Maskable::ActiveRecordModel
    #   end
    #
    #   User.where(id: [1, 2, 3]).mask_with_exwiw!
    #   User.where(organization_id: 1).mask_with_exwiw!(dry_run: true).statements
    #   User.all.mask_with_exwiw!   # refused: nothing narrows the rows
    #   user.mask_with_exwiw!
    #
    # Refers to ActiveRecord only inside methods (as ::ActiveRecord), so loading it needs no ActiveRecord.
    module ActiveRecordModel
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Masks this record's row in place and, unless `dry_run`, reloads the record.
      #
      # @param options [Hash] as for ClassMethods#mask_with_exwiw!
      # @return [Exwiw::Maskable::Result]
      # @raise [Exwiw::MaskUpdateRunner::Error] when the record is not persisted, or its row cannot be masked as declared
      def mask_with_exwiw!(**options)
        raise MaskUpdateRunner::Error, "#{self.class.name} is not persisted, so it has no row to mask" unless persisted?

        # unscoped: a default scope must not hide the record's own row.
        result = self.class.unscoped.where(self.class.primary_key => id_in_database).mask_with_exwiw!(**options)
        reload unless options[:dry_run]
        result
      end

      module ClassMethods
        # Masks the rows of the current relation. A relation with no condition of its own (the model itself, `all`,
        # `unscoped`, or only the default scope) is refused, as it would mask every row. Wrap the call in a transaction
        # to make it all-or-nothing, and split a large relation: `relation.in_batches { |batch| batch.mask_with_exwiw! }`.
        #
        # @param touch [Boolean] also set the model's update timestamps (updated_at) to the current time
        # @param dry_run [Boolean] only build the UPDATE statements, without executing them
        # @param profile [String, nil] the schema profile to apply. The schema is found through the class methods
        #   `exwiw_config_path` and `exwiw_schema_dir` when the class defines them (see Exwiw::Maskable.schema_for)
        # @param allow_constant_columns [Array<String>] credential-looking "table.column"s accepted as non-NULL masks
        # @return [Exwiw::Maskable::Result] statements are SQL UPDATEs
        # @raise [Exwiw::MaskUpdateRunner::Error] when nothing narrows the rows, or they cannot be masked as declared; nothing is updated then
        def mask_with_exwiw!(touch: true, dry_run: false, profile: nil, allow_constant_columns: [])
          scope = current_scope
          if scope.nil? || scope.where_clause.empty? || scope.where_clause == default_scoped.where_clause
            raise MaskUpdateRunner::Error,
                  "#{name}.mask_with_exwiw! has no condition narrowing the rows, so it would mask every row; narrow it with where"
          end

          options = { touch: touch, dry_run: dry_run, profile: profile, allow_constant_columns: allow_constant_columns }
          # with_connection appeared in ActiveRecord 7.2.
          return mask_with_connection(connection, **options) unless respond_to?(:with_connection)

          with_connection { |connection| mask_with_connection(connection, **options) }
        end

        private def mask_with_connection(connection, touch:, dry_run:, profile:, allow_constant_columns:)
          ids = all.pluck(arel_table[primary_key])
          now = connection.quoted_date(current_time_from_proper_timezone) if touch
          source = DataSource.given(Maskable::ActiveRecordModel.exwiw_adapter_name(connection), connection.raw_connection)
          summary, statements = Maskable.plan(
            source: source,
            schema: Maskable.schema_for(self, source, profile),
            table_name: table_name, ids: ids,
            extra_assignments: touch ? timestamp_attributes_for_update_in_model.to_h { |name| [name, now] } : {},
            allow_constant_columns: allow_constant_columns, logger: logger,
          )
          # Writes go through ActiveRecord, not the raw connection, so its transaction and query cache see them.
          statements.each { |sql| connection.execute(sql) } unless dry_run
          Result.new(summary: summary, statements: statements)
        end
      end

      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @return [String] the exwiw adapter name for the connection
      def self.exwiw_adapter_name(connection)
        # Adapter::ADAPTER_ALIASES leaves out trilogy on purpose, so a given Trilogy client is named as mysql here.
        connection.adapter_name.casecmp?("trilogy") ? "mysql" : connection.adapter_name
      end
    end
  end
end
