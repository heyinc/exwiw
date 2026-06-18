# frozen_string_literal: true

require 'json'
require 'set'

# NOTE: This adapter consumes MongodbCollectionConfig (`fields` instead of
# `columns`, plus `embedded_in`). Top-level collections are dumped as one
# jsonl per collection; configs marked `embedded_in` are not dumped on their
# own — their masking rules apply to subdocuments inside the parent.
module Exwiw
  module Adapter
    class MongodbAdapter < Base
      def self.table_config_class
        Exwiw::MongodbCollectionConfig
      end

      # A lazy, streaming stand-in for the materialized result array #execute
      # used to return. Wrapping the Mongo cursor (instead of `.to_a`) keeps the
      # dump's dominant memory cost — the full result set — off the heap: the
      # Runner pulls documents through `each_slice`, so at most one chunk of
      # documents (plus the small propagation-key arrays) is resident at a time,
      # even for large or embed-heavy collections.
      #
      # It satisfies the two things the Runner asks of an execute result:
      #   - #size: the record count, used to skip empty collections and to log.
      #     Answered with a `count_documents` query (which only walks index
      #     entries, far cheaper than fetching every document) rather than by
      #     draining the cursor.
      #   - #each (via Enumerable / each_slice): a single streaming pass over the
      #     cursor. While streaming it captures — per propagation key, BEFORE
      #     handing the document to the caller's masking — the values downstream
      #     children will `$in`-match against, publishing them into @state once
      #     the pass completes.
      #
      # Contract note: unlike the old `.to_a` execute, which populated @state
      # eagerly, this defers state capture until the result is consumed. The
      # Runner always fully consumes a non-empty result before any child
      # collection is processed, so propagation is unaffected; a caller that only
      # needs @state must iterate the result (e.g. `.to_a`).
      class StreamingResult
        include Enumerable

        def initialize(view:, collection:, keys:, state:)
          @view = view
          @collection = collection
          @keys = keys
          @state = state
        end

        def size
          @size ||= @view.count_documents
        end
        alias length size

        def each
          return enum_for(:each) { size } unless block_given?

          captured = @keys.each_with_object({}) { |key, acc| acc[key] = [] }
          @view.each do |doc|
            @keys.each { |key| captured[key] << doc[key] }
            yield doc
          end
          @state[@collection] = captured
          self
        end
      end

      def initialize(connection_config, logger)
        super
        @state = {}
      end

      def dumpable?(config)
        !config.embedded?
      end

      def validate_as_dump_target!(config)
        return unless config.embedded?

        raise NotImplementedError,
              "dump_target '#{config.name}' is an embedded MongodbCollectionConfig; " \
              "specify a top-level collection instead."
      end

      def build_query(config, dump_target, config_by_name)
        if config.embedded?
          raise NotImplementedError,
                "MongodbAdapter#build_query was called with embedded config '#{config.name}'. " \
                "Embedded configs are masked through the parent collection."
        end

        reject_filter!(config)
        # Stash the embedded-children index for the matching to_bulk_insert call
        # below. The Adapter contract does not pass config_by_name to
        # to_bulk_insert (SQL adapters don't need it), so we rely on the Runner
        # invariant that build_query is always called before to_bulk_insert for
        # the same config.
        @embedded_children_by_parent = index_embedded_children(config_by_name)

        # Which of this collection's fields downstream children will `$in`-match
        # against (always including primary_key). Stashed for the matching
        # #execute call to capture, by the same build_query-before-execute
        # invariant the embedded index relies on.
        @propagation_keys = propagation_keys_for(config, config_by_name)

        filter =
          if config.name == dump_target.table_name
            # `--ids-field` may override which field --ids is matched against;
            # otherwise fall back to the primary key. Note this only changes the
            # WHERE filter on the target collection — downstream foreign-key
            # propagation keys off each child belongs_to's `references` field
            # (default: the parent primary_key); see #execute, which stashes
            # those fields into @state.
            #
            # Type coercion is only applied to the primary key (`_id`), whose
            # stored type we know (Mongoid's default ObjectId). For a custom
            # `ids_field` the stored type is unknown, so the textual --ids are
            # left as Strings rather than guessed at — the caller passes values
            # matching the field's actual type.
            if dump_target.ids_field
              { dump_target.ids_field => { "$in" => dump_target.ids } }
            else
              { config.primary_key => { "$in" => coerce_ids(dump_target.ids) } }
            end
          else
            related_collection_filter(config, config_by_name)
          end

        Exwiw::MongoQuery::Find.new(
          collection: config.name,
          primary_key: config.primary_key,
          filter: filter,
          projection: build_projection(config, @propagation_keys),
        )
      end

      def execute(query)
        @logger.debug("  Executing Mongo find on '#{query.collection}': filter=#{query.filter.inspect} projection=#{query.projection.inspect}")

        view = db[query.collection]
          .find(query.filter)
          .projection(query.projection)
          .comment(query_comment_text("collection=#{query.collection}"))

        # Per referenced field, the values children will `$in`-match against.
        # @propagation_keys is set by the build_query call for this same
        # collection; fall back to the primary key if execute is driven without a
        # preceding build_query (e.g. in isolation from a test).
        keys = @propagation_keys || [query.primary_key]

        # Return a streaming view of the result set rather than `.to_a`-ing the
        # whole collection into memory. The Runner pulls documents through
        # `each_slice`, so only one chunk's worth is resident at a time even for
        # large / embed-heavy collections — the dump's dominant memory cost. The
        # propagation-key values are captured as the cursor streams and published
        # into @state once the pass completes (see StreamingResult).
        StreamingResult.new(view: view, collection: query.collection, keys: keys, state: @state)
      end

      # NOTE: relies on @embedded_children_by_parent set by a prior build_query
      # call for the same config. This implicit ordering exists because the
      # Adapter contract intentionally does not thread config_by_name through
      # to_bulk_insert (SQL adapters don't need it). Safe in Runner, fragile in
      # tests — call build_query first.
      def to_bulk_insert(rows, config)
        rows.map do |doc|
          apply_replace_with!(doc, config)
          apply_embedded_masking!(doc, config)
          JSON.generate(extended_json(doc))
        end.join("\n")
      end

      def to_bulk_delete(_query, _config)
        raise NotImplementedError, "MongodbAdapter does not support bulk delete"
      end

      def explain(_query)
        raise NotImplementedError, "MongodbAdapter does not support explain yet"
      end

      def describe_query(query)
        "find collection=#{query.collection} filter=#{query.filter.inspect} projection=#{query.projection.inspect}"
      rescue => e
        "<unavailable: #{e.class}: #{e.message}>"
      end

      def output_extension
        'jsonl'
      end

      # Bound how many documents are serialized at once when a collection config
      # carries no explicit bulk_insert_chunk_size. A MongoDB dump is one JSONL
      # line per document and, without chunking, the Runner would materialize the
      # entire collection's output as a single giant string while the full
      # in-memory result set is still alive — doubling peak memory on large or
      # embed-heavy collections. Chunking lets the Runner stream each slice to the
      # file and release its serialized string (and the transient extended-JSON
      # trees) before building the next.
      DEFAULT_BULK_INSERT_CHUNK_SIZE = 1_000

      def default_bulk_insert_chunk_size
        DEFAULT_BULK_INSERT_CHUNK_SIZE
      end

      def schema_output_extension
        'js'
      end

      # Index options copied through to the emitted createIndex call. Anything
      # else (`v`, `ns`, server-internal fields) is dropped — they would either
      # be rejected by createIndex or are not portable across mongod versions.
      INDEX_OPTION_ALLOWLIST = %w[
        unique sparse hidden expireAfterSeconds collation
        partialFilterExpression wildcardProjection
      ].freeze

      def dump_schema(ordered_tables, output_path)
        require 'json'

        collections = ordered_tables.reject(&:embedded?)

        # Index listing targets a specific collection, and MongoDB raises
        # NamespaceNotFound (code 26) for one that does not exist. The schema may
        # declare collections absent from this database (schema/DB drift, or a
        # sparse dev DB), so resolve the set that actually exists up front and emit
        # indexes only for those. `createCollection` is still emitted for every
        # config below, so the target schema is created in full regardless.
        existing_collections = db.database.collection_names.to_set

        File.open(output_path, 'w') do |file|
          file.puts("// Auto-generated by exwiw. Apply with: mongosh \"$MONGODB_URI\" #{File.basename(output_path)}")
          file.puts

          collections.each do |config|
            name = config.name
            file.puts(%(try { db.createCollection(#{JSON.generate(name)}); } catch (e) { if (e.code !== 48) throw e; }))
          end
          file.puts

          collections.each do |config|
            name = config.name
            unless existing_collections.include?(name)
              @logger.debug("  Collection '#{name}' is not present in the source database; emitting no indexes.")
              next
            end

            indexes = db[name].indexes.to_a.reject { |idx| idx['name'] == '_id_' }
            indexes.each do |idx|
              key = idx['key']
              opts = idx.slice(*INDEX_OPTION_ALLOWLIST)
              opts['name'] = idx['name'] if idx['name']
              file.puts(%(db.getCollection(#{JSON.generate(name)}).createIndex(#{JSON.generate(key)}, #{JSON.generate(opts)});))
            end
          end
        end
        @logger.info("  Wrote schema for #{collections.size} collection(s) to #{output_path}.")
      end

      def supports_bulk_delete?
        false
      end

      # `--ids` from the CLI arrives as Strings. Mongo compares types strictly,
      # so the textual ids must be coerced to the type actually stored in `_id`:
      #
      # - integer-looking ids -> Integer
      # - 24-char hex ids -> BSON::ObjectId (Mongoid's default `_id` type; a
      #   plain String would never match an ObjectId in a `$in` filter)
      # - anything else (e.g. a String/UUID `_id`) is left as-is
      #
      # Only used for the primary-key filter; a custom `--ids-field` skips this
      # because its stored type is unknown (see build_query).
      private def coerce_ids(ids)
        Array(ids).map { |id| coerce_id(id) }
      end

      private def coerce_id(id)
        return id unless id.is_a?(String)

        if id.match?(/\A-?\d+\z/)
          id.to_i
        elsif object_id_hex?(id)
          BSON::ObjectId.from_string(id)
        else
          id
        end
      end

      # True when `str` is a canonical 24-char hex ObjectId. `bson` ships with
      # `mongo`/`mongoid` but may not be loaded yet when build_query runs before
      # any db access, so require it lazily; if it is genuinely unavailable we
      # fall back to leaving the id as a String.
      private def object_id_hex?(str)
        require 'bson' unless defined?(::BSON::ObjectId)
        ::BSON::ObjectId.legal?(str)
      rescue LoadError
        false
      end

      private def reject_filter!(config)
        return if config.filter.nil? || config.filter.to_s.empty?

        raise NotImplementedError,
              "collection-level `filter` is not supported by MongodbAdapter (collection: #{config.name})"
      end

      private def index_embedded_children(config_by_name)
        config_by_name.each_value.with_object({}) do |child, acc|
          next unless child.embedded?

          (acc[child.embedded_in.collection_name] ||= []) << child
        end
      end

      private def build_projection(config, propagation_keys = [config.primary_key])
        projection = {}
        # Always include primary key so masking templates referencing it work,
        # even if it is not declared in fields.
        projection[config.primary_key] = 1
        config.fields.each do |field|
          projection[field.name] = 1
        end
        # Pull in paths owned by configs that mark themselves embedded in this
        # collection, so the masker sees the subdocuments.
        embedded_children_of(config).each do |child|
          projection[child.embedded_in.path] = 1
        end
        # Ensure every field a child references is fetched, even one not declared
        # in `fields` — otherwise doc[ref] would be nil and the child's $in empty.
        propagation_keys.each { |key| projection[key] = 1 }
        projection
      end

      # The distinct set of this collection's fields that downstream children
      # constrain on (each child belongs_to's `references`, defaulting to this
      # collection's primary_key), with primary_key always included so the
      # historical primary-key-keyed propagation keeps working.
      private def propagation_keys_for(config, config_by_name)
        referenced = config_by_name.each_value.flat_map do |child|
          next [] if child.embedded?

          child.belongs_tos
            .select { |relation| relation.table_name == config.name }
            .map { |relation| relation.references || config.primary_key }
        end
        ([config.primary_key] + referenced).uniq
      end

      # Build the scoping filter for a non-target collection from its belongs_to
      # parents' captured ids. Each belongs_to is constrained by the parent field
      # the FK references (`relation.references`, default the parent primary_key);
      # the values were captured from that field in #execute, so their BSON type
      # already matches the stored FK — no coercion.
      #
      # A belongs_to whose parent produced no ids contributes no constraint:
      # either the parent matched nothing, or it is not dumped here (e.g. an
      # embedded collection, or one excluded from the run). If that leaves the
      # filter empty even though the collection HAS belongs_to, the collection
      # cannot be scoped from the dump target — and falling back to an empty `{}`
      # filter would scan and dump the ENTIRE collection across every scope. That
      # is never what a scoped extraction wants, so constrain it to match nothing
      # and warn instead. (A collection with no belongs_to at all is genuine
      # reference/master data and is still dumped in full via `{}`.)
      private def related_collection_filter(config, config_by_name)
        filter = config.belongs_tos.each_with_object({}) do |relation, acc|
          values = parent_state_for(relation, config_by_name)
          next if values.nil? || values.empty?

          acc[relation.foreign_key] = { "$in" => values }
        end

        return filter unless filter.empty? && config.belongs_tos.any?

        @logger.warn(
          "  Collection '#{config.name}' has belongs_to but no parent produced ids to scope by " \
          "(parents matched nothing, or are not dumped on their own such as embedded collections). " \
          "Constraining it to match no rows to avoid an unscoped full-collection dump."
        )
        { config.primary_key => { "$in" => [] } }
      end

      # The captured parent-collection values a child belongs_to should be
      # constrained by: the values of the parent field the FK references
      # (`relation.references`, default the parent primary_key). nil when the
      # parent has not been executed yet.
      private def parent_state_for(relation, config_by_name)
        parent_fields = @state[relation.table_name]
        return nil if parent_fields.nil?

        reference_field =
          relation.references || config_by_name.fetch(relation.table_name).primary_key
        parent_fields[reference_field]
      end

      private def apply_replace_with!(doc, config)
        config.fields.each do |field|
          next unless field.replace_with

          doc[field.name] = field.replace_with.gsub(/\{([^{}]+)\}/) do
            ref = Regexp.last_match(1)
            (doc.key?(ref) ? doc[ref] : nil).to_s
          end
        end
      end

      private def apply_embedded_masking!(doc, parent_config)
        embedded_children_of(parent_config).each do |child|
          walk(doc, child.embedded_in.path) do |subdoc|
            apply_replace_with!(subdoc, child)
            apply_embedded_masking!(subdoc, child)
          end
        end
      end

      private def embedded_children_of(parent_config)
        @embedded_children_by_parent.fetch(parent_config.name, [])
      end

      private def walk(doc, dotted_path)
        segments = dotted_path.split(".")
        *prefix, last = segments
        container = prefix.reduce(doc) { |acc, seg| acc.is_a?(Hash) ? acc[seg] : nil }
        return unless container.is_a?(Hash)

        value = container[last]
        case value
        when Array then value.each { |sub| yield sub if sub.is_a?(Hash) }
        when Hash  then yield value
        end
      end

      private def extended_json(doc)
        if doc.respond_to?(:as_extended_json)
          doc.as_extended_json(mode: :relaxed)
        else
          doc
        end
      end

      private def db
        @db ||=
          begin
            require 'mongo'
            Mongo::Logger.logger.level = ::Logger::WARN
            if uri_connection?
              # A full connection URI (e.g. `mongodb+srv://...`) is the source of
              # truth: TLS, replicaSet, authSource and credentials are read from
              # it, so host/port/user/password are ignored. `--database`, if
              # given, overrides the database in the URI path; otherwise the
              # URI's own database is used. The URI is never logged (it may carry
              # credentials).
              client_options = {}
              if @connection_config.database_name && !@connection_config.database_name.to_s.empty?
                client_options[:database] = @connection_config.database_name
              end
              Mongo::Client.new(@connection_config.uri, **client_options)
            else
              address = "#{@connection_config.host}:#{@connection_config.port}"
              options = { database: @connection_config.database_name }
              if @connection_config.user && !@connection_config.user.to_s.empty?
                options[:user] = @connection_config.user
                options[:password] = @connection_config.password
              end
              Mongo::Client.new([address], **options)
            end
          end
      end

      private def uri_connection?
        !@connection_config.uri.nil? && !@connection_config.uri.to_s.empty?
      end
    end
  end
end
