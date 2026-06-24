# frozen_string_literal: true

require "set"

module Exwiw
  # Classifies a MongoDB dump's collections into the three dependency groups the
  # inter-collection fork schedule needs, plus the derived adjacency that
  # schedule consumes. See docs/mongodb-dump-parallelism-2x-notes.md for the why;
  # this class is the static, config-derived half of that plan.
  #
  # It is a pure function of the loaded configs and the dump target — no DB
  # access — so it can be computed once up front and unit-tested without a live
  # MongoDB. The fork orchestration (worker pools, LPT bin-packing on output-size
  # weights, @state Marshal sidecars, the Phase-2 cascade loop) lives elsewhere
  # and consumes the structures produced here.
  #
  # Input contract: `configs` are MongodbCollectionConfig already passed through
  # `#reject_ignored_members!` (exactly as Runner#load_table_config produces
  # them), so every surviving belongs_to has a non-nil `table_name`. ignore:true
  # *collections* are still present in `configs` — they contribute to the schema
  # and to the file-index ordering, but their data extraction is skipped — and
  # are therefore excluded from the three processing groups.
  #
  # The three groups partition the extractable collections exactly:
  #
  # - **genuine**  — reachable to the dump target by following belongs_to edges
  #                  (the scoped DAG). Includes the target itself.
  # - **leaf**     — no belongs_to at all: reference/master data dumped in full,
  #                  with no input dependencies (embarrassingly parallel).
  # - **ref_bt**   — has belongs_to but is NOT reachable to the target: reference
  #                  data scoped by the adapter's strict-AND fallback. Its
  #                  internal edges form shallow components.
  #
  # `reachable` mirrors MongodbAdapter#genuine_scope_set exactly (fixpoint over
  # all non-embedded configs, including ignore:true ones), so the genuine set
  # here matches the adapter's runtime scoping classification.
  class MongodbParallelPlan
    EMPTY_NAMES = [].freeze
    private_constant :EMPTY_NAMES

    # @param configs [Array<MongodbCollectionConfig>] reject_ignored_members!'d
    # @param target_table_name [String] the dump target collection
    # @param logger [Logger, nil] forwarded to DetermineTableProcessingOrder
    def initialize(configs:, target_table_name:, logger: nil)
      @by = configs.each_with_object({}) { |c, h| h[c.name] = c }
      @target_table_name = target_table_name

      dumpable = configs.reject(&:embedded?)
      # The file index (insert-NNN-) is taken over the FULL processing order,
      # including ignore:true collections, so the orchestrated run's filenames
      # are byte-identical to the serial Runner's (which numbers files the same
      # way). Data extraction, however, skips ignore:true — see #extractable.
      @ordered_all = DetermineTableProcessingOrder.run(dumpable, logger: logger).freeze
      @index_of = @ordered_all.each_with_index.to_h.freeze
      @extractable = @ordered_all.reject { |n| @by[n].ignore }.freeze

      @reachable = compute_reachable
      classify
      derive_consumed_leaves
      derive_cascade_adjacency
      @reference_components = compute_reference_components.freeze
    end

    # Full processing order, INCLUDING ignore:true collections — the sequence the
    # file index (insert-NNN-) is numbered over.
    attr_reader :ordered_all

    # name => 0-based position in #ordered_all (the file index is position + 1).
    attr_reader :index_of

    # #ordered_all minus ignore:true collections — the collections whose data is
    # actually extracted. Union of the three groups below.
    attr_reader :extractable

    # The three groups (each a subset of #extractable, in #ordered_all order):

    # genuine — reachable to the dump target (includes the target).
    attr_reader :genuine

    # leaf — no belongs_to; reference/master data with no input dependencies.
    attr_reader :leaves

    # ref_bt — has belongs_to but not reachable to the target.
    attr_reader :ref_bt

    # ref_bt collections as dependency-closed weakly-connected components over
    # intra-ref_bt belongs_to edges, each returned in a valid topological order
    # (a parent before its child). A whole component can be processed serially by
    # one worker with no cross-worker @state IPC and no level barriers, seeded
    # only with the leaf @state its members reference.
    attr_reader :reference_components

    # Leaf collections referenced (via belongs_to) by some non-leaf extractable
    # collection (genuine OR ref_bt). These are the only leaves whose captured
    # @state a downstream collection can need, so they are the ones a leaf worker
    # must hand back (e.g. as a Marshal sidecar). Set<String>.
    attr_reader :consumed_leaves

    # genuine collections that directly reference a leaf — the only genuine
    # collections whose output can change once leaf @state is present (and only
    # at runtime, when their genuine anchor turns out empty and they fall back to
    # the leaf clause). These seed the Phase-2 cascade reprocess.
    attr_reader :direct_leaf_genuine

    # name => genuine children (genuine collections that belongs_to it), keyed
    # only by reachable parents. Drives the Phase-2 cascade: when a reprocessed
    # collection's row count changes, its genuine children are re-enqueued.
    attr_reader :genuine_children

    # The set of collection names genuinely scoped by the target (the target plus
    # everything that can reach it through belongs_to). Exposed for inspection.
    attr_reader :reachable

    def summary
      {
        extractable: @extractable.size,
        genuine: @genuine.size,
        leaves: @leaves.size,
        ref_bt: @ref_bt.size,
        consumed_leaves: @consumed_leaves.size,
        direct_leaf_genuine: @direct_leaf_genuine.size,
        reference_components: @reference_components.map(&:size).sort.reverse,
      }
    end

    private

    # Fixpoint over non-embedded configs: the target, plus every collection that
    # can reach it by following belongs_to (child -> parent) transitively.
    # Mirrors MongodbAdapter#genuine_scope_set (same traversal, same inclusion of
    # ignore:true collections) so the genuine set matches the adapter's runtime
    # scoping decision.
    def compute_reachable
      reachable = Set.new([@target_table_name])
      loop do
        added = false
        @by.each_value do |cfg|
          next if cfg.embedded? || reachable.include?(cfg.name)
          next unless cfg.belongs_tos.any? { |rel| reachable.include?(rel.table_name) }

          reachable << cfg.name
          added = true
        end
        break unless added
      end
      reachable
    end

    def classify
      # The three groups partition #extractable: reachable -> genuine; otherwise
      # leaf (no belongs_to) -> leaves; otherwise -> ref_bt. The target is
      # reachable (it seeds the set), so it lands in genuine and is never
      # mis-grouped as a leaf even when it has no belongs_to of its own — which
      # would otherwise double-process it (leaf pool AND parent).
      @genuine = []
      @leaves = []
      @ref_bt = []
      @extractable.each do |name|
        if @reachable.include?(name)
          @genuine << name
        elsif leaf?(name)
          @leaves << name
        else
          @ref_bt << name
        end
      end
      @genuine.freeze
      @leaves.freeze
      @ref_bt.freeze
      # Membership against the leaf *group* (which excludes the target), not the
      # raw structural #leaf? predicate. The target has no belongs_to and is thus
      # structurally leaf-like, but it is genuine — processed by the parent, not a
      # leaf worker — so a belongs_to to the target must not count as referencing
      # a leaf (it would wrongly demand a sidecar / seed the cascade).
      @leaf_set = @leaves.to_set
    end

    def derive_consumed_leaves
      consumed = Set.new
      (@genuine + @ref_bt).each do |name|
        @by[name].belongs_tos.each do |rel|
          consumed << rel.table_name if @leaf_set.include?(rel.table_name)
        end
      end
      @consumed_leaves = consumed.freeze
    end

    def derive_cascade_adjacency
      @direct_leaf_genuine = @genuine.select do |name|
        @by[name].belongs_tos.any? { |rel| @leaf_set.include?(rel.table_name) }
      end.freeze

      children = Hash.new { |h, k| h[k] = [] }
      @genuine.each do |name|
        @by[name].belongs_tos.each do |rel|
          children[rel.table_name] << name if @reachable.include?(rel.table_name)
        end
      end
      # Freeze with a non-mutating default so a lookup of a parent with no genuine
      # children returns [] without trying to write into the frozen hash.
      children.default_proc = nil
      children.default = EMPTY_NAMES
      @genuine_children = children.freeze
    end

    # ref_bt as dependency-closed weakly-connected components over intra-ref_bt
    # belongs_to edges, each topo-ordered. Ported from the bench prototype: build
    # the directed (child indegree) and undirected (component) views of the
    # intra-ref_bt edges, find weakly-connected components, then Kahn-order each.
    def compute_reference_components
      ref_set = @ref_bt.to_set
      children = Hash.new { |h, k| h[k] = [] }
      adjacency = Hash.new { |h, k| h[k] = [] }
      @ref_bt.each do |name|
        @by[name].belongs_tos.each do |rel|
          next unless ref_set.include?(rel.table_name)

          children[rel.table_name] << name
          adjacency[rel.table_name] << name
          adjacency[name] << rel.table_name
        end
      end

      seen = Set.new
      components = []
      @ref_bt.each do |start|
        next if seen.include?(start)

        stack = [start]
        members = []
        until stack.empty?
          node = stack.pop
          next if seen.include?(node)

          seen << node
          members << node
          adjacency[node].each { |neighbor| stack << neighbor unless seen.include?(neighbor) }
        end
        components << members
      end

      components.map { |members| topo_order(members, children) }
    end

    # Kahn topological order of `members` over intra-component belongs_to edges
    # (parent before child). `children` is the directed intra-ref_bt adjacency.
    def topo_order(members, children)
      member_set = members.to_set
      indegree = members.to_h do |name|
        [name, @by[name].belongs_tos.count { |rel| member_set.include?(rel.table_name) }]
      end
      queue = members.select { |name| indegree[name].zero? }
      ordered = []
      until queue.empty?
        node = queue.shift
        ordered << node
        children[node].each do |child|
          next unless member_set.include?(child)

          indegree[child] -= 1
          queue << child if indegree[child].zero?
        end
      end
      ordered
    end

    def leaf?(name)
      (cfg = @by[name]) && !cfg.embedded? && cfg.belongs_tos.empty?
    end
  end
end
