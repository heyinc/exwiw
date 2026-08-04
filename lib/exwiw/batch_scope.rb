# frozen_string_literal: true

module Exwiw
  # Opt-in configuration for *batched* extraction (see {BatchedExtraction}).
  #
  # A table is normally extracted with one query whose scope filter sits on the
  # table it joins up to. On a very large table that query can degrade badly:
  # once the scope keeps enough rows, the planner stops believing the foreign-key
  # index is worth it and switches to a full scan of the whole (multi-hundred
  # million row) table — which then runs past the server's `statement_timeout`,
  # or simply for hours. The rows it would have returned are a small slice of the
  # table; the plan, not the data, is the problem.
  #
  # `batch_scope` slices that one query into several. `table` names the scoped
  # table this table reaches — the *batch table* — and exwiw resolves its
  # in-scope primary keys once, then extracts this table one `size`-sized slice
  # of those ids at a time:
  #
  #   "batch_scope": { "table": "customers", "size": 1000 }
  #
  # Each batch's query carries `customers.id IN (<1000 ids>)` in place of the
  # scope filter, which is small and selective enough that the foreign-key index
  # is always the cheaper plan. The dumped rows are the same as the unbatched
  # query's — every id is covered exactly once, so no row is dropped or emitted
  # twice.
  #
  # User-configured and never emitted by the schema generators, like
  # `scope_column` / `scope_exempt` / `reverse_scope`, and preserved across
  # regeneration (see {TableConfig#merge}).
  class BatchScope
    include Serdes

    # Ids per batch when `size` is omitted. Small enough that the planner keeps
    # choosing the foreign-key index, large enough that the per-query overhead
    # stays negligible against the rows each batch returns.
    DEFAULT_SIZE = 1_000

    attribute :table, String
    attribute :size, optional(Integer), skip_serializing_if_nil: true
    attribute :comment, optional(String), skip_serializing_if_nil: true

    def batch_size
      size || DEFAULT_SIZE
    end
  end
end
