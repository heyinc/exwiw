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

          # Shared with the cursor-parallel dump's per-worker capture: the same
          # PropagationCapture guarantees serial and parallel paths leave
          # byte-identical @state (see PropagationCapture).
          capture = PropagationCapture.new(@keys)
          @view.each do |doc|
            capture.observe(doc)
            yield doc
          end
          @state[@collection] = capture.to_h
          self
        end
      end

      def initialize(connection_config, logger, parallel_workers: nil)
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
        plan = mask_plan(config)
        rows.map { |doc| serialize_document(doc, plan) }.join("\n")
      end

      # Write the chunk's JSONL straight to `io`, optionally serializing the
      # documents across forked worker processes.
      #
      # The dump's dominant cost is per-document `as_extended_json` +
      # `JSON.generate` (pure Ruby, so it holds the GVL — threads give no
      # speedup; only separate processes use more cores). When parallelism is
      # opted in (see #parallel_workers), ParallelSerializer forks workers that
      # COW-inherit `rows`, each serializing its contiguous slice to a part file,
      # and the parent concatenates them in slice order — byte-for-byte identical
      # to the serial `to_bulk_insert` join (the Runner inserts the same "\n"
      # between chunks either way). The mask plan is built in the parent before
      # the fork so every worker inherits it instead of recompiling it.
      #
      # Default (parallelism off): the serial Base path, unchanged. Parallelism
      # trades memory (a larger resident chunk, see #default_bulk_insert_chunk_size)
      # for wall-clock, so streaming stays the memory-safe default.
      def write_bulk_insert(io, rows, config)
        workers = parallel_workers
        return super if workers <= 1

        plan = mask_plan(config)
        ParallelSerializer.write(
          io, rows, workers: workers, separator: "\n", min_batch: parallel_min_batch
        ) { |doc| serialize_document(doc, plan) }
        nil
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

      # Documents handed to each forked worker per parallel chunk. Fork + part-file
      # + concat overhead only amortizes on batches in the thousands (measured by
      # script/bench_mongodb_parallel_probe.rb), so when parallelism is on the
      # chunk is sized to give every worker a multi-thousand-doc slice rather than
      # the serial 1_000-doc chunk (which would fall back to serial inside
      # ParallelSerializer). The trade-off is a larger resident chunk — the memory
      # cost paid for the ~2x speedup.
      PARALLEL_DOCS_PER_WORKER = 4_000

      def default_bulk_insert_chunk_size
        workers = parallel_workers
        return DEFAULT_BULK_INSERT_CHUNK_SIZE if workers <= 1

        [DEFAULT_BULK_INSERT_CHUNK_SIZE, workers * PARALLEL_DOCS_PER_WORKER].max
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

      # A masking plan compiled once per collection config and reused for every
      # document of that collection. `masked_fields` is `[field_name,
      # template_segments]` for each field carrying a `replace_with`;
      # `embedded` is one EmbeddedMask per embedded child.
      MaskPlan = Struct.new(:masked_fields, :embedded)

      # A pre-resolved embedded-child mask: the parent path split once into
      # `prefix` (the containers to descend into) and `last` (the field holding
      # the subdocument(s)), plus the child's own MaskPlan.
      EmbeddedMask = Struct.new(:prefix, :last, :plan)

      # Build (or fetch) the cached MaskPlan for `config`. Masking runs over every
      # document AND every embedded subdocument, so for an embed-heavy collection
      # the same per-config decisions — which fields carry a `replace_with`, how
      # each template splits into segments, where the embedded children live —
      # were previously recomputed tens of times per document. Compiling them once
      # per config lets #apply_mask_plan! do nothing but the work that actually
      # varies per document (rendering templates, descending into subdocuments),
      # so the saved per-subdocument overhead scales down with embedding count.
      #
      # Cached by config name: names are unique within a run and the configs do
      # not mutate mid-dump. Relies on @embedded_children_by_parent, set by the
      # build_query call that always precedes to_bulk_insert (see #to_bulk_insert).
      private def mask_plan(config)
        (@mask_plans ||= {})[config.name] ||= build_mask_plan(config)
      end

      private def build_mask_plan(config)
        masked_fields = config.fields.each_with_object([]) do |field, acc|
          next unless field.replace_with

          acc << [field.name, compile_template(field.replace_with)]
        end
        embedded = embedded_children_of(config).map do |child|
          *prefix, last = child.embedded_in.path.split(".")
          EmbeddedMask.new(prefix, last, build_mask_plan(child))
        end
        MaskPlan.new(masked_fields, embedded)
      end

      # Apply a precompiled MaskPlan to a document in place: render each masked
      # field, then descend into each embedded child (recursing into its own
      # plan). Equivalent to the old apply_replace_with! + apply_embedded_masking!
      # pair, with all per-config lookups hoisted into the plan.
      private def apply_mask_plan!(doc, plan)
        plan.masked_fields.each do |name, segments|
          doc[name] = render_template(segments, doc)
        end
        plan.embedded.each do |child|
          container = child.prefix.reduce(doc) { |acc, seg| acc.is_a?(Hash) ? acc[seg] : nil }
          next unless container.is_a?(Hash)

          case (value = container[child.last])
          when Array then value.each { |sub| apply_mask_plan!(sub, child.plan) if sub.is_a?(Hash) }
          when Hash  then apply_mask_plan!(value, child.plan)
          end
        end
      end

      PLACEHOLDER_PATTERN = /\{([^{}]+)\}/

      # Split a `replace_with` template into a flat list of segments (called once
      # per masked field at plan-build time, see #build_mask_plan). A segment is
      # either a literal String or a 1-element Array `[ref]` marking a `{ref}`
      # placeholder. #render_template then concatenates them, skipping the regex
      # scan / block / `Regexp.last_match` a per-document `gsub` would repeat (~2.5x
      # faster per field). The segment walk reproduces the old gsub byte-for-byte
      # (missing keys render as "", literals pass through unchanged).
      private def compile_template(template)
        segments = []
        pos = 0
        while (md = PLACEHOLDER_PATTERN.match(template, pos))
          segments << template[pos...md.begin(0)] if md.begin(0) > pos
          segments << [md[1]]
          pos = md.end(0)
        end
        segments << template[pos..] if pos < template.length
        segments
      end

      private def render_template(segments, doc)
        out = +''
        segments.each do |seg|
          if seg.is_a?(Array)
            ref = seg[0]
            out << (doc.key?(ref) ? doc[ref] : nil).to_s
          else
            out << seg
          end
        end
        out
      end

      private def embedded_children_of(parent_config)
        @embedded_children_by_parent.fetch(parent_config.name, [])
      end

      # Mask a single document in place and encode it to one JSONL line. The unit
      # of work shared by the serial #to_bulk_insert and the parallel
      # #write_bulk_insert so both produce identical bytes per document.
      private def serialize_document(doc, plan)
        apply_mask_plan!(doc, plan)
        JSON.generate(extended_json(doc))
      end

      # Number of worker processes to fork for serialization. Opt-in: the CLI
      # `--parallel-workers=N` flag (threaded in as @parallel_workers_option)
      # takes precedence, falling back to the EXWIW_MONGODB_PARALLEL_WORKERS env
      # var for programmatic/Railtie callers that never touch the CLI. Unset or
      # <=1 means the serial, memory-safe default. Read once and memoized so the
      # chunk size and the write path agree within a run.
      private def parallel_workers
        @parallel_workers ||= begin
          n = @parallel_workers_option || ENV["EXWIW_MONGODB_PARALLEL_WORKERS"].to_i
          n > 1 ? n : 1
        end
      end

      # Minimum chunk size before forking is worthwhile; below it
      # ParallelSerializer falls back to a serial (still byte-identical) write.
      private def parallel_min_batch
        ParallelSerializer::DEFAULT_MIN_BATCH
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
