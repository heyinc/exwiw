# frozen_string_literal: true

module Exwiw
  module Maskable
    # Adds `mask_with_exwiw!` to a Mongoid document class and its criteria. Documents are read (from the primary) and
    # updated through the model's collection (its client, database and persistence context), by bulk writes that
    # bypass callbacks, in the caller's session (transaction) when one is open. Without a transaction, the documents
    # a failed bulk write wrote before it stay masked.
    #
    #   class User
    #     include Mongoid::Document
    #     include Exwiw::Maskable::MongoidDocument
    #   end
    #
    #   User.where(:_id.in => ids).mask_with_exwiw!
    #   User.all.mask_with_exwiw!   # refused: nothing narrows the documents
    #   user.mask_with_exwiw!
    #
    # Refers to Mongoid only inside methods, so loading it needs no Mongoid.
    module MongoidDocument
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Masks this document in place and, unless `dry_run`, reloads it.
      #
      # @param options [Hash] as for ClassMethods#mask_with_exwiw!
      # @return [Exwiw::Maskable::Result]
      # @raise [Exwiw::MaskUpdateRunner::Error] when the document is not persisted, or cannot be masked as declared
      def mask_with_exwiw!(**options)
        raise MaskUpdateRunner::Error, "#{self.class.name} is not persisted, so it has no document to mask" unless persisted?
        if embedded?
          raise MaskUpdateRunner::Error,
                "#{self.class.name} is embedded; its masks apply through the parent's documents, so mask the parent instead"
        end

        # unscoped: a default scope must not hide the document itself.
        result = self.class.unscoped.where(_id: _id).mask_with_exwiw!(**options)
        reload unless options[:dry_run]
        result
      end

      module ClassMethods
        # Masks the documents of the current criteria. A criteria with no condition of its own (the model itself,
        # `all`, `unscoped`, or only the default scope) is refused, as it would mask every document.
        #
        # @param touch [Boolean] also set `updated_at` (when the model has the field) to the current time
        # @param dry_run [Boolean] only build the bulk writes, without executing them
        # @param profile [String, nil] the schema profile to apply. The schema is found through the class methods
        #   `exwiw_config_path` and `exwiw_schema_dir` when the class defines them (see Exwiw::Maskable.schema_for)
        # @param allow_constant_columns [Array<String>] credential-looking "collection.path"s accepted as constant masks
        # @return [Exwiw::Maskable::Result] statements are `[collection, operations]` as canonical Extended JSON
        # @raise [Exwiw::MaskUpdateRunner::Error] when nothing narrows the documents, the class is embedded, or the documents
        #   cannot be masked as declared; nothing is written then
        def mask_with_exwiw!(touch: true, dry_run: false, profile: nil, allow_constant_columns: [])
          if embedded?
            raise MaskUpdateRunner::Error,
                  "#{name} is embedded; its masks apply through the parent's documents, so mask the parent instead"
          end
          scope = ::Mongoid::Threaded.current_scope(self)
          if scope.nil? || scope.selector.empty? || scope.selector == exwiw_default_selector
            raise MaskUpdateRunner::Error,
                  "#{name}.mask_with_exwiw! has no condition narrowing the documents, so it would mask every document; narrow it with where"
          end

          # Read from the primary: a secondary may not have the documents yet, or hold older values to mask from.
          # The collection's client points at the model's database (its persistence context included).
          client = collection.client.with(read: { mode: :primary })
          # Mongoid keeps an open session (a transaction's) per thread; reading and writing in it joins the transaction.
          session = ::Mongoid::Threaded.get_session(client: mongo_client)
          source = DataSource.given("mongodb", client, session: session)
          summary, bulk_writes = Maskable.plan(
            source: source,
            schema: Maskable.schema_for(self, source, profile),
            table_name: collection_name.to_s,
            ids: all.read(mode: :primary).pluck(:_id),
            extra_assignments: touch && fields.key?("updated_at") ? { "updated_at" => Time.now.utc } : {},
            allow_constant_columns: allow_constant_columns, logger: logger,
          )
          unless dry_run
            bulk_writes.each do |bulk_write|
              client[bulk_write.collection_name].bulk_write(bulk_write.driver_operations, session ? { session: session } : {})
            end
          end
          Result.new(summary: summary, statements: bulk_writes.map(&:to_extended_json))
        end

        # The default scope's lambda calls `where` on the class, which would chain onto the current criteria, so the
        # current scope is set aside while it runs.
        private def exwiw_default_selector
          return {} unless default_scoping

          current = ::Mongoid::Threaded.current_scope(self)
          ::Mongoid::Threaded.set_current_scope(nil, self)
          ::Mongoid::Criteria.new(self).tap(&:apply_default_scope).selector
        ensure
          ::Mongoid::Threaded.set_current_scope(current, self) if current
        end
      end
    end
  end
end
