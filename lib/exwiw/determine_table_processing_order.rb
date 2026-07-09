# frozen_string_literal: true

require "set"

module Exwiw
  module DetermineTableProcessingOrder
    module_function

    # @param tables [Array<Exwiw::TableConfig>] tables
    # @param logger [Logger, nil] receives a warning when a cycle has to be broken
    # @param runtime_reverse_scope [Boolean] when true (mongodb), a table
    #   declaring `reverse_scope` is ordered AFTER its `via` referencer tables:
    #   the adapter builds the reverse filter from ids captured at runtime while
    #   the referencers were dumped, so they must be processed first. Each arm's
    #   own belongs_to edge back to the reverse-scoped table (the usual
    #   `referencer.fk -> hub` relation) is inverted rather than kept, since the
    #   declaration states ids flow referencer -> hub. False (the default)
    #   preserves the historical belongs_to-only ordering — the SQL adapters
    #   scope via subqueries and need the hub emitted before its referencers so
    #   the INSERT output stays loadable in foreign-key order.
    # @return [Array<String>] sorted table names
    def run(tables, logger: nil, runtime_reverse_scope: false)
      return tables.map(&:name) if tables.size < 2

      ordered_table_names = []
      ordered = Set.new

      table_by_name = tables.each_with_object({}) do |table, acc|
        acc[table.name] = table
      end

      reverse_scope_deps = runtime_reverse_scope ? compute_reverse_scope_dependencies(tables) : {}
      dependencies_by_name = tables.each_with_object({}) do |table, acc|
        acc[table.name] = compute_dependencies(table, reverse_scope_deps)
      end

      # Only relations whose target is also in this run constrain the order. A
      # dependency pointing at a table that is not being processed here — e.g.
      # an embedded MongoDB collection (masked through its parent, never dumped
      # on its own) or any table excluded from the run — is not something we can
      # or need to order against, so it must never block resolution. Without
      # this, such a dependency would stay unresolved forever and masquerade as
      # a circular dependency, freezing every table that (transitively)
      # references it.
      present_names = table_by_name.keys.to_set

      loop do
        break if table_by_name.empty?

        resolvable = table_by_name.values.select do |table|
          unresolved_dependencies(table.name, dependencies_by_name, present_names, ordered).empty?
        end

        if resolvable.empty?
          # No table has all its (in-run) dependencies satisfied, yet tables
          # remain: the dependency graph has a genuine cycle and no strict
          # topological order exists.
          #
          # When a reverse_scope ordering edge participates in the cycle, there
          # is no safe way out: emitting the reverse-scoped table before an arm
          # would build its filter from missing state (silently dropping rows),
          # so fail loudly instead of guessing.
          detect_reverse_scope_cycle!(table_by_name, dependencies_by_name, reverse_scope_deps, present_names, ordered)

          # Otherwise the cycle is a plain belongs_to cycle. Rather than
          # aborting the whole export, break it by emitting one cycle member;
          # see pick_cycle_victim for how the member is chosen. Warn so the
          # dropped constraint is visible.
          victim = pick_cycle_victim(table_by_name.values, dependencies_by_name, present_names, ordered)
          warn_cycle_break(logger, victim, unresolved_dependencies(victim.name, dependencies_by_name, present_names, ordered))
          resolvable = [victim]
        end

        # In the normal (acyclic) path, emit every currently-resolvable table in
        # insertion order — preserving the historical ordering the snapshot specs
        # depend on. The cycle-break path emits exactly its single chosen victim.
        resolvable.each do |table|
          ordered_table_names << table.name
          ordered << table.name
          table_by_name.delete(table.name)
        end
      end

      ordered_table_names
    end

    # The belongs_to target table names of `table`. A polymorphic belongs_to is
    # expanded into one entry per concrete target by schema generation, so each
    # entry is a plain table name here.
    def compute_table_dependencies(table)
      table.belongs_tos.map(&:table_name)
    end

    # reverse_scope ordering edges: reverse-scoped table name => its `via`
    # referencer table names (the tables that must be processed before it).
    private_class_method def compute_reverse_scope_dependencies(tables)
      tables.each_with_object({}) do |table, acc|
        next unless table.respond_to?(:reverse_scope)

        arm_tables = (table.reverse_scope&.via || []).map(&:table).uniq
        acc[table.name] = arm_tables if arm_tables.any?
      end
    end

    # The ordering dependencies of `table`: its belongs_to targets — minus any
    # belongs_to pointing at a reverse-scoped table that names `table` as a
    # `via` arm (that edge is inverted: the arm feeds the reverse-scoped table
    # its ids, so the arm goes first) — plus, when `table` itself is
    # reverse-scoped, its `via` referencer tables.
    private_class_method def compute_dependencies(table, reverse_scope_deps)
      deps = compute_table_dependencies(table).reject do |dep|
        reverse_scope_deps[dep]&.include?(table.name)
      end
      deps += reverse_scope_deps[table.name] || []
      deps.uniq
    end

    # The dependencies still blocking `table_name`: dependency targets that are
    # part of this run, not yet ordered, and not the table itself (a
    # self-referential dependency never blocks).
    private_class_method def unresolved_dependencies(table_name, dependencies_by_name, present_names, ordered)
      dependencies_by_name.fetch(table_name).select do |dep|
        present_names.include?(dep) && !ordered.include?(dep) && dep != table_name
      end
    end

    # Raise when the stall is caused by a reverse_scope ordering edge: a
    # reverse-scoped table and one of its `via` arms sit in the same non-trivial
    # strongly-connected component, so no processing order can put every arm
    # before the table. Typical shape: two reverse-scoped tables naming each
    # other as arms, or an arm that (transitively) belongs_to the table it
    # feeds. A plain belongs_to cycle (no reverse_scope edge involved) returns
    # without raising, leaving the historical cycle-break to handle it.
    private_class_method def detect_reverse_scope_cycle!(table_by_name, dependencies_by_name, reverse_scope_deps, present_names, ordered)
      return if reverse_scope_deps.empty?

      adjacency = table_by_name.each_key.each_with_object({}) do |name, acc|
        acc[name] = unresolved_dependencies(name, dependencies_by_name, present_names, ordered)
      end
      cyclic_names = strongly_connected_members(adjacency)

      offenders = cyclic_names.select do |name|
        (reverse_scope_deps[name] || []).any? { |arm| cyclic_names.include?(arm) }
      end
      return if offenders.empty?

      details = offenders.sort.map { |name| "'#{name}' (via: #{(reverse_scope_deps[name] & cyclic_names.to_a).sort.join(', ')})" }
      raise ArgumentError,
            "reverse_scope creates an ordering cycle: #{details.join('; ')}. " \
            "A reverse-scoped collection must be processed after all of its reverse_scope.via " \
            "referencers, but these dependencies form a cycle with the belongs_to/reverse_scope " \
            "graph (cycle members: #{cyclic_names.to_a.sort.join(', ')}). Remove one of the " \
            "reverse_scope arms, or break the belongs_to edge that closes the cycle with `ignore: true`."
    end

    # Choose the next table to emit when the order is stuck in a cycle. Only
    # genuine cycle members are eligible — a table in a non-trivial
    # strongly-connected component of the unresolved-dependency subgraph — so an
    # acyclic table that merely waits on a cycle is never reordered ahead of its
    # parent. Among the members, prefer one that still has at least one
    # already-ordered parent, so its extraction stays constrained instead of
    # collapsing to "match every row" (a cross-scope over-extraction risk for the
    # mongodb adapter); break remaining ties by fewest unresolved dependencies,
    # then by name, for determinism.
    private_class_method def pick_cycle_victim(remaining, dependencies_by_name, present_names, ordered)
      adjacency = remaining.each_with_object({}) do |table, acc|
        acc[table.name] = unresolved_dependencies(table.name, dependencies_by_name, present_names, ordered)
      end
      cyclic_names = strongly_connected_members(adjacency)

      candidates = remaining.select { |table| cyclic_names.include?(table.name) }
      candidates = remaining if candidates.empty? # defensive; a stall implies a cycle

      anchored = candidates.select { |table| ordered_parent?(table.name, dependencies_by_name, present_names, ordered) }
      pool = anchored.empty? ? candidates : anchored

      pool.min_by { |table| [unresolved_dependencies(table.name, dependencies_by_name, present_names, ordered).size, table.name] }
    end

    # True when `table_name` has a dependency whose target was already ordered,
    # so its extraction filter will be constrained rather than an unscoped full
    # scan.
    private_class_method def ordered_parent?(table_name, dependencies_by_name, present_names, ordered)
      dependencies_by_name.fetch(table_name).any? do |dep|
        dep != table_name && present_names.include?(dep) && ordered.include?(dep)
      end
    end

    # Names belonging to a non-trivial strongly-connected component (size > 1) of
    # `adjacency` (table name -> unresolved dependency names), i.e. the genuine
    # cycle participants. Iterative Tarjan; nodes and edges are visited in name
    # order so the result is deterministic. Self-edges are already excluded from
    # the adjacency, so a size-1 component is never a cycle.
    private_class_method def strongly_connected_members(adjacency)
      index = {}
      low = {}
      on_stack = {}
      stack = []
      counter = 0
      members = Set.new
      neighbors = adjacency.each_with_object({}) { |(name, deps), acc| acc[name] = deps.sort }

      adjacency.keys.sort.each do |start|
        next if index.key?(start)

        work = [[start, 0]]
        until work.empty?
          node, edge_i = work.last
          if edge_i.zero?
            index[node] = counter
            low[node] = counter
            counter += 1
            stack.push(node)
            on_stack[node] = true
          end

          adj = neighbors[node] || []
          if edge_i < adj.size
            work.last[1] += 1
            w = adj[edge_i]
            next unless adjacency.key?(w) # ignore edges leaving the remaining set

            if index.key?(w)
              low[node] = [low[node], index[w]].min if on_stack[w]
            else
              work.push([w, 0])
            end
          else
            if low[node] == index[node]
              component = []
              loop do
                w = stack.pop
                on_stack[w] = false
                component << w
                break if w == node
              end
              members.merge(component) if component.size > 1
            end
            work.pop
            low[work.last[0]] = [low[work.last[0]], low[node]].min unless work.empty?
          end
        end
      end

      members
    end

    private_class_method def warn_cycle_break(logger, victim, dropped)
      return if logger.nil?

      logger.warn(
        "Circular belongs_to dependency detected. Breaking it by ordering " \
        "'#{victim.name}' before its parent table(s): #{dropped.join(', ')}. The dropped " \
        "relationship is not enforced while ordering, so '#{victim.name}' is extracted " \
        "without that parent constraint (the mongodb adapter may then match a superset of " \
        "rows; SQL output may not load in foreign-key order). To break the cycle explicitly " \
        "instead, mark one of the belongs_to entries forming it with `ignore: true`."
      )
    end
  end
end
