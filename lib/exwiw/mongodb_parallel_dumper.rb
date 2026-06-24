# frozen_string_literal: true

require "set"
require "fileutils"
require "tmpdir"

module Exwiw
  # Runs the inter-collection fork schedule from
  # docs/mongodb-dump-parallelism-2x-notes.md, producing output **byte-identical**
  # to the serial Runner while parallelizing the dominant cost (the Mongo driver's
  # BSON->Ruby decode) across processes — each worker decodes its own collections
  # in their natural order, so order is preserved and the result still matches a
  # serial dump.
  #
  # It consumes the static, config-derived classification from MongodbParallelPlan
  # (the three groups + cascade adjacency + ref_bt components) and adds the live
  # orchestration the plan deliberately leaves out: a fork pool per group, LPT
  # bin-packing on a per-collection cost weight, @state Marshal sidecar IPC for the
  # handful of referenced leaves, and the Phase-2 cascade reprocess.
  #
  # The schedule (one parent process + a pool of `workers` forks):
  #
  #   Phase 1 (concurrent): fork the leaf pool; the parent meanwhile dumps the
  #     schema and processes the WHOLE genuine DAG optimistically (no leaf @state
  #     yet), recording each genuine collection's row count.
  #   Barrier: wait for the leaf pool; load the Marshal sidecars the consumed
  #     leaves wrote into the parent's @state.
  #   Phase 2 (cascade): reprocess only the genuine collections whose output can
  #     change now that leaf @state is present (the direct-leaf referencers),
  #     cascading to genuine children of any whose row count actually changed.
  #   Phase 3: fork the ref_bt collections as dependency-closed components, each
  #     worker owning whole components (processed in topological order) seeded with
  #     the leaf @state its members reference.
  #
  # Output bytes are independent of the schedule: every collection writes its own
  # insert-NNN-<name>.<ext> file (the index taken over the plan's full ordering,
  # exactly as the serial Runner numbers them) and the per-collection write is the
  # same build_query -> execute -> write_inserts pass the Runner performs. The
  # bin-packing only decides which worker runs which collection, never the bytes.
  #
  # fork is required; callers must check {.available?} and fall back to the serial
  # Runner on JRuby/TruffleRuby/Windows.
  class MongodbParallelDumper
    # True when the runtime can `fork` (CRuby on a POSIX OS). On JRuby/TruffleRuby
    # and Windows it cannot — the caller must run the serial Runner instead.
    def self.available?
      Process.respond_to?(:fork)
    end

    # Longest-Processing-Time bin-packing: assign `items` to `bins` bins, heaviest
    # first onto the currently least-loaded bin. Returns an Array of `bins` arrays
    # (some may be empty when items < bins). `weight` is called exactly once per
    # item (it may be DB-backed, so it must not be invoked repeatedly). Pure — no
    # DB, no IO — so it is unit-tested directly.
    def self.bin_pack(items, bins, &weight)
      raise ArgumentError, "bins must be >= 1 (got #{bins})" if bins < 1

      weighted = items.map { |item| [item, weight.call(item)] }.sort_by { |(_, w)| -w }
      groups = Array.new(bins) { [] }
      loads = Array.new(bins, 0)
      weighted.each do |(item, w)|
        i = (0...bins).min_by { |j| loads[j] }
        groups[i] << item
        loads[i] += w
      end
      groups
    end

    # @param connection_config [ConnectionConfig] used to build a FRESH adapter in
    #   the parent and in every fork (a Mongo client cannot be shared across fork)
    # @param plan [MongodbParallelPlan] the static classification for this dump
    # @param dump_target [DumpTarget]
    # @param table_by_name [Hash{String=>config}] ALL configs (embedded included),
    #   exactly as Runner builds it
    # @param output_dir [String]
    # @param workers [Integer] fork pool size (>= 1)
    # @param logger [Logger]
    # @param weight_for [#call, nil] optional name -> numeric cost weight for LPT;
    #   defaults to the adapter's metadata-only estimated document count
    def initialize(connection_config:, plan:, dump_target:, table_by_name:, output_dir:, workers:, logger:, weight_for: nil)
      raise ArgumentError, "workers must be >= 1 (got #{workers})" if workers < 1

      @connection_config = connection_config
      @plan = plan
      @dump_target = dump_target
      @table_by_name = table_by_name
      @output_dir = output_dir
      @workers = workers
      @logger = logger
      @weight_for = weight_for
    end

    # Execute the full schedule. Assumes the caller has already cleaned the output
    # directory (the Runner does this before handing off), mirroring the serial
    # path which dumps the schema into a freshly-cleaned dir. Returns a small stats
    # Hash. Raises if any worker pool reports a non-zero exit.
    def run
      raise "fork is unavailable on this runtime; run the serial Runner instead" unless self.class.available?

      FileUtils.mkdir_p(@output_dir)
      parent = build_adapter

      Dir.mktmpdir("exwiw-mongo-parallel-") do |sidecar_dir|
        phase1_leaf_and_genuine(parent, sidecar_dir)
        phase2_cascade(parent, sidecar_dir)
        phase3_ref_components(parent, sidecar_dir)
      end

      {
        workers: @workers,
        genuine: @plan.genuine.size,
        leaves: @plan.leaves.size,
        ref_bt: @plan.ref_bt.size,
        components: @plan.reference_components.map(&:size).sort.reverse,
      }
    end

    private

    # Phase 1: fork the leaf pool to run concurrently while the parent dumps the
    # schema (parent-only, needs no @state) and processes the whole genuine DAG
    # optimistically. The genuine row counts captured here seed the Phase-2 cascade.
    def phase1_leaf_and_genuine(parent, sidecar_dir)
      leaf_master = fork do
        ok = run_leaf_pool(sidecar_dir)
        exit!(ok ? 0 : 1)
      end

      schema_path = File.join(@output_dir, "insert-000-schema.#{parent.schema_output_extension}")
      ordered_tables = @plan.ordered_all.map { |name| @table_by_name.fetch(name) }
      @logger.info("Writing schema to #{schema_path}...")
      parent.dump_schema(ordered_tables, schema_path)

      @logger.info("Processing #{@plan.genuine.size} genuine collection(s) (parent, optimistic pass)...")
      @row_counts = {}
      @plan.genuine.each { |name| @row_counts[name] = process_collection(parent, name) }

      Process.wait(leaf_master)
      raise "exwiw parallel leaf pool failed (exit #{$?.exitstatus})" unless $?.exitstatus&.zero?
    end

    # Barrier + Phase 2: load the consumed-leaf @state the leaf workers handed back,
    # then reprocess only the genuine collections whose output can change now that
    # leaf @state is present, cascading to genuine children of any that changed.
    def phase2_cascade(parent, sidecar_dir)
      load_sidecars(parent, @plan.consumed_leaves, sidecar_dir)

      queue = @plan.direct_leaf_genuine.dup
      seen = Set.new
      until queue.empty?
        name = queue.shift
        next if seen.include?(name)

        seen << name
        new_count = process_collection(parent, name)
        next if new_count == @row_counts[name]

        @row_counts[name] = new_count
        @plan.genuine_children[name].each { |child| queue << child }
      end
      @logger.info("Cascade reprocessed #{seen.size} genuine collection(s) with leaf @state.") unless seen.empty?
    end

    # Phase 3: fork the ref_bt collections as dependency-closed weakly-connected
    # components in a single pool (no level barriers, no cross-worker IPC). Each
    # worker owns whole components and processes their members in topological order,
    # seeded only with the leaf @state those members reference.
    def phase3_ref_components(parent, sidecar_dir)
      components = @plan.reference_components
      return if components.empty?

      leaf_state = parent.state
      groups = self.class.bin_pack(components, @workers) { |component| component.sum { |name| weight_of(parent, name) } }

      pids = groups.reject(&:empty?).map do |group|
        members = group.flatten
        seed = leaf_state.slice(*parents_of(members))
        fork { run_component_worker(group, seed) }
      end
      ok = pids.map { |pid| Process.wait(pid); $?.exitstatus&.zero? }.all?
      raise "exwiw parallel ref_bt pool failed" unless ok

      @logger.info("Processed #{@plan.ref_bt.size} ref_bt collection(s) in #{groups.reject(&:empty?).size} worker(s).")
    end

    # Fork `@workers` leaf workers (LPT-packed on cost weight so the single heaviest
    # leaf sits alone) and wait for them. Each worker writes a Marshal sidecar for
    # the consumed leaves it produced. Runs inside the leaf_master fork, so its own
    # weight adapter and the worker connections never touch the parent's.
    def run_leaf_pool(sidecar_dir)
      return true if @plan.leaves.empty?

      weight_adapter = build_adapter
      groups = self.class.bin_pack(@plan.leaves, @workers) { |name| weight_of(weight_adapter, name) }

      pids = groups.reject(&:empty?).map do |group|
        fork { run_leaf_worker(group, sidecar_dir) }
      end
      pids.map { |pid| Process.wait(pid); $?.exitstatus&.zero? }.all?
    rescue StandardError => e
      @logger.error("exwiw parallel leaf master error: #{e.class}: #{e.message}")
      false
    end

    def run_leaf_worker(group, sidecar_dir)
      adapter = build_adapter
      group.each { |name| process_collection(adapter, name) }
      group.each do |name|
        next unless @plan.consumed_leaves.include?(name)
        next unless adapter.state.key?(name)

        File.binwrite(File.join(sidecar_dir, "#{name}.marshal"), Marshal.dump(adapter.state[name]))
      end
      exit!(0)
    rescue StandardError => e
      @logger.error("exwiw parallel leaf worker error (#{group.first}..): #{e.class}: #{e.message}")
      exit!(1)
    end

    def run_component_worker(group, seed)
      adapter = build_adapter
      adapter.state = seed unless seed.empty?
      # Each component is already topologically ordered (parent before child) and
      # dependency-closed over intra-ref_bt edges, so a plain serial walk suffices.
      group.each { |component| component.each { |name| process_collection(adapter, name) } }
      exit!(0)
    rescue StandardError => e
      @logger.error("exwiw parallel ref_bt worker error (#{group.first&.first}..): #{e.class}: #{e.message}")
      exit!(1)
    end

    # Extract one collection to its insert-NNN-<name>.<ext> file. This mirrors the
    # serial Runner's non-COPY insert path exactly — same filename (index taken over
    # the plan's full ordering), same pre/post hooks (nil for MongoDB), same
    # streaming write_inserts + trailing "\n", and the same empty-result handling
    # (delete the just-opened file) — so the bytes are identical regardless of which
    # process writes them. Returns the row count.
    def process_collection(adapter, name)
      table = @table_by_name.fetch(name)
      query = adapter.build_query(table, @dump_target, @table_by_name)
      results = adapter.execute(query)

      insert_idx = (@plan.index_of.fetch(name) + 1).to_s.rjust(3, "0")
      path = File.join(@output_dir, "insert-#{insert_idx}-#{name}.#{adapter.output_extension}")
      chunk_size = table.bulk_insert_chunk_size || adapter.default_bulk_insert_chunk_size

      record_num = 0
      File.open(path, "w") do |file|
        pre = adapter.pre_insert_sql(table)
        file.puts(pre) if pre
        _statement_count, record_num = adapter.write_inserts(file, results, table, chunk_size)
        file.print("\n")
        post = adapter.post_insert_sql(table)
        file.puts(post) if post
      end
      File.delete(path) if record_num.zero?
      record_num
    end

    # Merge the Marshal sidecars the leaf workers wrote (one per consumed leaf that
    # actually produced rows) into `adapter`'s @state, so the cascade reprocess and
    # the ref_bt workers can constrain on those leaf ids.
    def load_sidecars(adapter, names, sidecar_dir)
      state = adapter.state
      names.each do |name|
        path = File.join(sidecar_dir, "#{name}.marshal")
        state[name] = Marshal.load(File.binread(path)) if File.exist?(path)
      end
    end

    # The distinct belongs_to parent names of `names`, used to slice the leaf @state
    # a worker is seeded with down to only the keys its collections reference.
    def parents_of(names)
      names.flat_map { |name| @table_by_name.fetch(name).belongs_tos.map(&:table_name) }.uniq
    end

    def weight_of(adapter, name)
      return @weight_for.call(name) if @weight_for

      adapter.estimated_count(name)
    end

    # A fresh adapter (and thus a fresh, lazily-opened Mongo connection). Built per
    # process — the parent and every fork get their own; a Mongo client must never
    # be shared across a fork boundary.
    def build_adapter
      Adapter.build(@connection_config, @logger)
    end
  end
end
