# frozen_string_literal: true

module Exwiw
  module Maskable
    # Adds `mask_with_exwiw!` to an ActiveRecord model and its relations. Rows are read and updated through the
    # model's connection, in batches each in a transaction that joins the caller's when one is open (see
    # ClassMethods#mask_with_exwiw!). Updates bypass callbacks.
    #
    #   class ApplicationRecord < ActiveRecord::Base
    #     include Exwiw::Maskable::ActiveRecordModel
    #   end
    #
    #   User.where(id: [1, 2, 3]).mask_with_exwiw!
    #   User.where(organization_id: 1).mask_with_exwiw!(dry_run: true).statements
    #   User.where(organization_id: 1).mask_with_exwiw! { |summary, statements| log(statements) }
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
      # @yield as for ClassMethods#mask_with_exwiw!
      # @return [Exwiw::Maskable::Result]
      # @raise [Exwiw::MaskUpdateRunner::Error] when the record is not persisted, or its row cannot be masked as declared
      def mask_with_exwiw!(**options, &block)
        raise MaskUpdateRunner::Error, "#{self.class.name} is not persisted, so it has no row to mask" unless persisted?

        # unscoped: a default scope must not hide the record's own row.
        result = self.class.unscoped.where(self.class.primary_key => id_in_database).mask_with_exwiw!(**options, &block)
        reload unless options[:dry_run]
        result
      end

      module ClassMethods
        # Masks the rows of the current relation. A relation with no condition of its own (the model itself, `all`,
        # `unscoped`, or only the default scope) is refused, as it would mask every row.
        #
        # @param touch [Boolean] also set the model's update timestamps (updated_at) to the current time
        # @param dry_run [Boolean] only build the UPDATE statements, without executing them
        # @param profile [String, nil] the schema profile to apply. The schema is found through the class methods
        #   `exwiw_config_path` and `exwiw_schema_dir` when the class defines them (see Exwiw::Maskable.schema_for)
        # @param batch [Boolean] mask the rows in batches (`in_batches` of MaskUpdateRunner::CHUNK_SIZE, ignoring the
        #   relation's order) and each batch in its own transaction, which joins the caller's when one is open; a
        #   failure leaves the batches before it masked. With false, the rows are read and updated at once in no
        #   transaction of its own; wrap the call in one to make it all-or-nothing
        # @yield [summary, statements] once each batch is done (after its transaction, or after the single batch
        #   with `batch: false`); the statements are then not kept in the result
        # @yieldparam summary [Exwiw::MaskUpdateRunner::Summary] the batch's summary
        # @yieldparam statements [Array<String>] the batch's SQL UPDATEs, executed unless `dry_run`
        # @return [Exwiw::Maskable::Result] statements are SQL UPDATEs with `dry_run` and no block, nil otherwise
        # @raise [Exwiw::MaskUpdateRunner::Error] when nothing narrows the rows, or they cannot be masked as declared; nothing of the batch is updated then
        def mask_with_exwiw!(touch: true, dry_run: false, profile: nil, batch: true, &block)
          scope = current_scope
          if scope.nil? || scope.where_clause.empty? || scope.where_clause == default_scoped.where_clause
            raise MaskUpdateRunner::Error,
                  "#{name}.mask_with_exwiw! has no condition narrowing the rows, so it would mask every row; narrow it with where"
          end

          options = { touch: touch, dry_run: dry_run, profile: profile, batch: batch }
          # with_connection appeared in ActiveRecord 7.2.
          return mask_with_connection(connection, **options, &block) unless respond_to?(:with_connection)

          with_connection { |connection| mask_with_connection(connection, **options, &block) }
        end

        # Whether the schema lets `mask_with_exwiw!` mask this model's rows: the table is declared, is not
        # `ignore: true`, rails-managed or keyed by a composite primary key, declares a mask on some column, and selects
        # its primary key without masking it. Reads the schema only, not the table, so a caller can skip a model
        # `mask_with_exwiw!` would refuse rather than rescue its error.
        #
        #   models.select(&:exwiw_maskable?).each { |model| model.where(user_id: id).mask_with_exwiw! }
        #
        # @param profile [String, nil] the schema profile to apply, as for #mask_with_exwiw!
        # @return [Boolean]
        def exwiw_maskable?(profile: nil)
          Maskable.maskable?(self, TableConfig, table_name, profile)
        end

        private def mask_with_connection(connection, touch:, dry_run:, profile:, batch:, &block)
          now = connection.quoted_date(current_time_from_proper_timezone) if touch
          source = DataSource.given(Maskable::ActiveRecordModel.exwiw_adapter_name(connection), connection.raw_connection)
          schema = Maskable.schema_for(self, source, profile)
          extra_assignments = touch ? timestamp_attributes_for_update_in_model.to_h { |name| [name, now] } : {}
          mask = lambda do |ids|
            summary, statements = Maskable.plan(
              source: source, schema: schema, table_name: table_name, ids: ids, extra_assignments: extra_assignments, logger: logger,
            )
            # Writes go through ActiveRecord, not the raw connection, so its transaction and query cache see them.
            statements.each { |sql| connection.execute(sql) } unless dry_run
            [summary, statements]
          end
          # Only a dry run without a block keeps the statements, so batches do not pile them up in memory otherwise.
          done = lambda do |(summary, statements)|
            block&.call(summary, statements)
            [summary, dry_run && !block ? statements : nil]
          end

          parts =
            if batch
              in_batches(of: MaskUpdateRunner::CHUNK_SIZE).map do |relation|
                ids = relation.pluck(arel_table[primary_key])
                done.(dry_run ? mask.(ids) : connection.transaction { mask.(ids) })
              end
            else
              [done.(mask.(all.pluck(arel_table[primary_key])))]
            end
          summary = MaskUpdateRunner::Summary.merge(table_name, parts.map(&:first))
          Result.new(summary: summary, statements: dry_run && !block ? parts.flat_map(&:last) : nil)
        end
      end

      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @return [String] the exwiw adapter name for the connection
      def self.exwiw_adapter_name(connection)
        Adapter.normalize_active_record_name(connection.adapter_name)
      end
    end
  end
end
