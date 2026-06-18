# frozen_string_literal: true

module Exwiw
  # Split a collection's matched `_id`s into contiguous, disjoint, exhaustive
  # ranges so that each range can be fetched by an INDEPENDENT cursor in
  # parallel. This is the boundary-computation foundation for a cursor-parallel
  # MongoDB dump.
  #
  # Why this matters: iteration 10 measured that the shipped fork-parallel
  # *serialization* path (ParallelSerializer behind `--parallel-workers`)
  # delivers only ~1.0–1.4x end-to-end on embed-heavy data, because ~40% of the
  # dump wall time is the Mongo cursor's BSON->Ruby decode, which runs serially
  # in the parent regardless of worker count (Amdahl-capped). Iteration 11's live
  # probe (`script/bench_mongodb_cursor_parallel_probe.rb`) showed that giving
  # each worker its OWN `_id` range + cursor splits that decode floor too,
  # delivering a byte-identical ~3.4x@4 / ~5.5x@8. The probe partitions the query
  # exactly the way this module does; extracting it makes that byte-identity
  # logic reusable and unit-testable without a database.
  #
  # Byte-identity contract (the reason this logic is delicate): both the serial
  # path (one cursor, `sort(_id: 1)`) and the parallel path (W disjoint `_id`
  # ranges, each `sort(_id: 1)`, concatenated in range order) emit the same
  # documents in the same order, so their outputs are byte-for-byte identical —
  # IF and only if the ranges are contiguous, disjoint, exhaustive, and ordered.
  # Every method here preserves that invariant.
  module MongoIdPartitioner
    module_function

    # Given `ids` already sorted ascending and unique (as `_id`s are within a
    # collection) and a positive `workers` count, return at most `workers`
    # contiguous `[lo, hi]` ranges — both bounds INCLUSIVE and drawn from `ids` —
    # that together cover every id exactly once, in ascending order.
    #
    # Pure (no database): this is the byte-identity-critical core, matching the
    # probe's partitioning exactly. Slices are sized `ceil(n / workers)` so the
    # range count never exceeds `workers` and no range is ever empty (fewer than
    # `workers` ranges are returned when `workers > ids.size`). Returns `[]` for
    # an empty `ids`.
    def ranges_from_sorted_ids(ids, workers)
      raise ArgumentError, "workers must be >= 1, got #{workers.inspect}" if workers < 1

      n = ids.size
      return [] if n.zero?

      slice_size = (n / workers.to_f).ceil
      ranges = []
      i = 0
      while i < n
        hi = [i + slice_size, n].min
        ranges << [ids[i], ids[hi - 1]]
        i = hi
      end
      ranges
    end

    # The inclusive-bounds filter fragment for one range, merged onto `base`.
    # Centralizing the `$gte`/`$lte` choice here keeps the byte-identity contract
    # in one tested place: a future cursor-parallel write path must use the SAME
    # inclusive bounds the ranges were computed with, or the per-range cursors
    # would skip or double-count the documents on a boundary. `base` is the
    # collection's normal scoping filter (e.g. the belongs_to `$in` constraint);
    # it is not mutated.
    def range_filter(base, primary_key, lo, hi)
      base.merge(primary_key => { "$gte" => lo, "$lte" => hi })
    end

    # Scan the matched `_id`s index-only and split them into ranges. `view` is a
    # Mongo::Collection::View carrying ONLY the collection's scoping filter (no
    # projection/sort — this method applies its own `{_id: 1}` projection and
    # `sort(_id: 1)` so the scan reads index entries, not whole documents).
    # `primary_key` is the id field name (`_id`). Returns `[]` when the view
    # matches nothing.
    #
    # The scan is the coordination cost a cursor-parallel dump pays up front; it
    # is far cheaper than decoding full documents but, on a very large
    # collection, still materializes every id client-side. A future optimization
    # could compute boundaries server-side via `$bucketAuto` / `splitVector`
    # without pulling all ids — but that produces a different (still valid)
    # partitioning, so it is deliberately out of scope for this byte-identity
    # foundation.
    def ranges_for(view, primary_key, workers)
      ids = view.projection(primary_key => 1).sort(primary_key => 1).map { |doc| doc[primary_key] }
      ranges_from_sorted_ids(ids, workers)
    end
  end
end
