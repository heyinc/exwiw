# frozen_string_literal: true

require 'json'

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

        filter =
          if config.name == dump_target.table_name
            # `--ids-field` may override which field --ids is matched against;
            # otherwise fall back to the primary key. Note this only changes the
            # WHERE filter on the target collection — downstream foreign-key
            # propagation still keys off `primary_key` (see #execute, which
            # stashes doc[primary_key] into @state).
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
            constrained = config.belongs_tos.select do |relation|
              @state.key?(relation.table_name) && !@state[relation.table_name].empty?
            end

            if constrained.empty?
              {}
            else
              constrained.each_with_object({}) do |relation, acc|
                acc[relation.foreign_key] = { "$in" => @state[relation.table_name] }
              end
            end
          end

        Exwiw::MongoQuery::Find.new(
          collection: config.name,
          primary_key: config.primary_key,
          filter: filter,
          projection: build_projection(config),
        )
      end

      def execute(query)
        @logger.debug("  Executing Mongo find on '#{query.collection}': filter=#{query.filter.inspect} projection=#{query.projection.inspect}")

        docs = db[query.collection]
          .find(query.filter)
          .projection(query.projection)
          .comment(query_comment_text("collection=#{query.collection}"))
          .to_a

        @state[query.collection] = docs.map { |doc| doc[query.primary_key] }

        docs
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

      private def build_projection(config)
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
        projection
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
