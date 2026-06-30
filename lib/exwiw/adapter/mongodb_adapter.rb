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

        def initialize(view:, collection:, keys:, state:, timeout_ms: nil)
          @view = view
          @collection = collection
          @keys = keys
          @state = state
          @timeout_ms = timeout_ms
        end

        def size
          # count_documents reads :timeout_ms only from the opts passed here (it
          # does not inherit the find view's per-op timeout), so the per-collection
          # value must be threaded in explicitly. When nil it falls back to the
          # client-wide global timeout, like every other operation.
          @size ||= @timeout_ms ? @view.count_documents(timeout_ms: @timeout_ms) : @view.count_documents
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
        @explain_placeholder = false
      end

      # A recognizably-fake ObjectId substituted for captured parent ids when
      # building scope filters in `explain` placeholder mode (see
      # #explain_scope_with_placeholders! and #parent_state_for).
      EXPLAIN_PLACEHOLDER_OID_HEX = "ffffffffffffffffffffffff"

      # Switch #build_query into placeholder-scope mode for `explain`. The
      # mongodb scope of a non-target collection is its parents' captured ids,
      # which the serial dump harvests at runtime in #execute. `explain` never
      # executes a query, so that @state stays empty and every scoped child would
      # otherwise fall back to the match-nothing `{_id: {$in: []}}` filter —
      # hiding which field (e.g. a foreign key) the real dump would actually
      # filter on, and thus whether it is indexed. In this mode #parent_state_for
      # returns a placeholder id for each dumped parent instead of reading
      # @state, so build_query emits the real foreign-key filter shape with a
      # dummy value. queryPlanner picks an index by the queried FIELD, not the
      # value, so index selection (IXSCAN vs COLLSCAN) is reported correctly even
      # though the bound value is fake.
      def explain_scope_with_placeholders!
        @explain_placeholder = true
      end

      # Propagation @state accessor, used ONLY by MongodbParallelDumper to seed a
      # forked worker with the slice of parent ids its collections reference and to
      # harvest the ids downstream collections will `$in`-match against (handed
      # between processes as Marshal sidecars). The serial Runner never touches
      # these — it relies on the in-process capture during #execute.
      attr_accessor :state

      # Cheap, metadata-only document-count estimate for `collection_name`, used by
      # the parallel dumper to weight collections for LPT bin-packing. This only
      # influences which worker processes a collection (never the output bytes), so
      # an imprecise estimate is harmless. Reads collection metadata rather than
      # running a COLLSCAN; returns 0 on any error (e.g. a collection absent from
      # this database just sorts to the lowest weight).
      def estimated_count(collection_name)
        db[collection_name].estimated_document_count
      rescue StandardError
        0
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
            related_collection_filter(config, config_by_name, dump_target)
          end

        Exwiw::MongoQuery::Find.new(
          collection: config.name,
          primary_key: config.primary_key,
          filter: filter,
          projection: build_projection(config, @propagation_keys),
          timeout_ms: config.query_timeout_ms,
        )
      end

      def execute(query)
        @logger.debug("  Executing Mongo find on '#{query.collection}': filter=#{query.filter.inspect} projection=#{query.projection.inspect}")

        view = db[query.collection]
          .find(query.filter, find_timeout_opts(query))
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
        StreamingResult.new(view: view, collection: query.collection, keys: keys, state: @state, timeout_ms: query.timeout_ms)
      end

      # NOTE: relies on @embedded_children_by_parent set by a prior build_query
      # call for the same config. This implicit ordering exists because the
      # Adapter contract intentionally does not thread config_by_name through
      # to_bulk_insert (SQL adapters don't need it). Safe in Runner, fragile in
      # tests — call build_query first.
      def to_bulk_insert(rows, config)
        plan = mask_plan(config)
        rows.map do |doc|
          apply_mask_plan!(doc, plan)
          Exwiw::ExtJson.encode(doc)
        end.join("\n")
      end

      def to_bulk_delete(_query, _config)
        raise NotImplementedError, "MongodbAdapter does not support bulk delete"
      end

      # Default explain verbosity. `queryPlanner` asks the server to PLAN the
      # query without executing it, so it is safe to run against a production
      # source — no documents are scanned or returned. `executionStats` and
      # `allPlansExecution` actually run the query to collect runtime stats (the
      # latter also runs the rejected candidate plans), so they carry the cost of
      # the real extraction query.
      DEFAULT_EXPLAIN_VERBOSITY = "queryPlanner"

      # Server-side explain for the find this dump would issue, returned as
      # pretty-printed relaxed extended JSON (same value semantics as the dumped
      # documents). `verbosity` is one of queryPlanner / executionStats /
      # allPlansExecution; see DEFAULT_EXPLAIN_VERBOSITY for the safety
      # implications. A String verbosity is passed through to the driver as-is.
      def explain(query, verbosity: nil)
        verbosity ||= DEFAULT_EXPLAIN_VERBOSITY
        @logger.debug("  Running explain (verbosity=#{verbosity}) on '#{query.collection}': filter=#{query.filter.inspect}")

        result = db[query.collection]
          .find(query.filter, find_timeout_opts(query))
          .projection(query.projection)
          .comment(query_comment_text("collection=#{query.collection}"))
          .explain(verbosity: verbosity)

        JSON.pretty_generate(result.as_extended_json(mode: :relaxed))
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

      # Per-operation find options carrying the collection's CSOT timeout. An
      # empty hash when the query has none, so the operation inherits the
      # client-wide global timeout (or runs untimed if that is also unset). The
      # find view's :timeout_ms governs the whole cursor lifetime — initial batch
      # plus every getMore the streaming dump walks — which is what makes it the
      # right cap for an accidentally heavy/unscoped extraction.
      private def find_timeout_opts(query)
        query.timeout_ms ? { timeout_ms: query.timeout_ms } : {}
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
      # Scope flows from the dump target along belongs_to edges. A belongs_to is
      # classified by whether its parent is *genuinely scoped* — reachable back to
      # the dump target through belongs_to chains (see #genuine_scope_set) — which
      # determines how its constraint is applied:
      #
      # - Among the genuine parents, the most selective one (fewest captured ids)
      #   is the ANCHOR and is applied strictly. It carries the real narrowing and,
      #   being strict, bounds the result to a small set — which keeps both this
      #   query and the `$in` sets it feeds downstream from ballooning.
      #
      # - The OTHER genuine parents are applied null-aware: a row whose (nullable)
      #   FK is null/absent has no reference through that relation and must not be
      #   excluded by it. `nil` is added to the `$in` set (Mongo's `$in: [nil]`
      #   matches both explicit nulls and missing fields). Without this, a nullable
      #   genuine FK that is null on otherwise in-scope rows ANDs the result to
      #   empty — dropping legitimate rows, and (when it zeroes a parent) making
      #   children lose that parent's selective+indexed scope and degenerate to a
      #   full COLLSCAN. See docs/mongodb-scoping-fullscan-notes.md. Null-aware is
      #   applied to non-anchor parents only: making the sole/anchor scope itself
      #   null-aware would match every row whose FK is null (e.g. a not-yet-
      #   backfilled column), ballooning the result instead of scoping it.
      #
      # - Reference parents (NOT reachable to the dump target — master/reference
      #   data dumped in full, or only reachable via such data) produce a non-
      #   scoping id set: "all/most of a reference table", which neither narrows
      #   meaningfully nor, made null-aware, stays bounded. So when the collection
      #   has a genuine parent to anchor on, reference-parent constraints are
      #   dropped entirely.
      #
      # When NO genuine parent produced ids, the collection is not reachable from
      # the dump target; fall back to the historical strict-AND of whatever
      # constraints exist (bounded, preserves prior behavior).
      #
      # A belongs_to whose parent produced no ids contributes no constraint: either
      # the parent matched nothing, or it is not dumped here (e.g. an embedded
      # collection, or one excluded from the run). If that leaves the filter empty
      # even though the collection HAS belongs_to, the collection cannot be scoped
      # from the dump target — and an empty `{}` filter would scan and dump the
      # ENTIRE collection across every scope. That is never what a scoped
      # extraction wants, so constrain it to match nothing and warn instead. (A
      # collection with no belongs_to at all is genuine reference/master data and
      # is still dumped in full via `{}`.)
      private def related_collection_filter(config, config_by_name, dump_target)
        genuine = genuine_scope_set(config_by_name, dump_target.table_name)

        genuine_clauses = []
        reference_clauses = []
        config.belongs_tos.each do |relation|
          values = parent_state_for(relation, config_by_name)
          next if values.nil? || values.empty?

          target = genuine.include?(relation.table_name) ? genuine_clauses : reference_clauses
          target << [relation.foreign_key, values]
        end

        filter =
          if genuine_clauses.any?
            anchor_index = (0...genuine_clauses.size).min_by { |i| genuine_clauses[i][1].size }
            genuine_clauses.each_with_index.each_with_object({}) do |((foreign_key, values), index), acc|
              acc[foreign_key] =
                index == anchor_index ? { "$in" => values } : { "$in" => [nil] + values }
            end
          else
            reference_clauses.each_with_object({}) do |(foreign_key, values), acc|
              acc[foreign_key] = { "$in" => values }
            end
          end

        return filter unless filter.empty? && config.belongs_tos.any?

        @logger.warn(
          "  Collection '#{config.name}' has belongs_to but no parent produced ids to scope by " \
          "(parents matched nothing, or are not dumped on their own such as embedded collections). " \
          "Constraining it to match no rows to avoid an unscoped full-collection dump."
        )
        { config.primary_key => { "$in" => [] } }
      end

      # The set of collection names *genuinely scoped* by the dump target: the
      # target itself, plus every collection that can reach it by following
      # belongs_to edges (child -> parent) transitively. Computed by fixpoint over
      # the configs. Everything outside this set is reference/master data (or only
      # reachable through it) whose belongs_to id sets do not represent a real
      # scope. Memoized per target name; the configs do not mutate mid-run.
      private def genuine_scope_set(config_by_name, target_name)
        (@genuine_scope_set_cache ||= {})[target_name] ||=
          begin
            reachable = Set.new([target_name])
            loop do
              added = false
              config_by_name.each_value do |cfg|
                next if cfg.embedded? || reachable.include?(cfg.name)
                next unless cfg.belongs_tos.any? { |relation| reachable.include?(relation.table_name) }

                reachable << cfg.name
                added = true
              end
              break unless added
            end
            reachable
          end
      end

      # The captured parent-collection values a child belongs_to should be
      # constrained by: the values of the parent field the FK references
      # (`relation.references`, default the parent primary_key). nil when the
      # parent has not been executed yet.
      #
      # In `explain` placeholder mode (#explain_scope_with_placeholders!) there is
      # no captured state, so return a one-element placeholder id for any dumped
      # (non-embedded) parent — enough to make the child's foreign-key clause
      # appear with its real field, so the plan reflects the real dump. An
      # embedded parent is not dumped on its own and yields nil, exactly as a real
      # run's empty @state would.
      private def parent_state_for(relation, config_by_name)
        if @explain_placeholder
          parent = config_by_name[relation.table_name]
          return nil if parent.nil? || parent.embedded?

          return [explain_placeholder_id]
        end

        parent_fields = @state[relation.table_name]
        return nil if parent_fields.nil?

        reference_field =
          relation.references || config_by_name.fetch(relation.table_name).primary_key
        parent_fields[reference_field]
      end

      # The placeholder id used in explain placeholder mode. Built lazily because
      # build_query can run before any db access loads bson; falls back to the
      # hex String if bson is genuinely unavailable (the filter shape is what
      # matters, not the value's type).
      private def explain_placeholder_id
        require 'bson' unless defined?(::BSON::ObjectId)
        @explain_placeholder_id ||= ::BSON::ObjectId.from_string(EXPLAIN_PLACEHOLDER_OID_HEX)
      rescue LoadError
        EXPLAIN_PLACEHOLDER_OID_HEX
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
          # Preserve a NULL / absent source value instead of clobbering it into a
          # masked literal. `doc[name].nil?` is true for both an explicit nil and
          # an absent key, so an absent key is left absent (not created).
          next if doc[name].nil?

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
              client_options = global_timeout_options
              if @connection_config.database_name && !@connection_config.database_name.to_s.empty?
                client_options[:database] = @connection_config.database_name
              end
              Mongo::Client.new(@connection_config.uri, **client_options)
            else
              address = "#{@connection_config.host}:#{@connection_config.port}"
              options = global_timeout_options.merge(database: @connection_config.database_name)
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

      # Client-level CSOT default applied to every operation on this connection
      # (find cursor lifetime, count, executing explain). nil when no global
      # timeout is configured, leaving the client untimed; a per-collection
      # `query_timeout_ms` still overrides this per find/count.
      private def global_timeout_options
        timeout = @connection_config.mongodb_query_timeout_ms
        timeout ? { timeout_ms: timeout } : {}
      end
    end
  end
end
