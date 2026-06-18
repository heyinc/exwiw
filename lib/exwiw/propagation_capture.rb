# frozen_string_literal: true

module Exwiw
  # Capture, per propagation key, the field values that downstream child
  # collections will `$in`-match against — the FK-propagation `@state` a dumped
  # MongoDB collection leaves behind for its children to scope by.
  #
  # Today the serial dump captures this in one pass as `MongodbAdapter::
  # StreamingResult` streams the single cursor (see StreamingResult#each). This
  # class factors that capture out so the SAME byte-identity-critical logic can be
  # reused by the cursor-parallel dump, where each forked worker fetches a
  # disjoint `_id` range and must capture its own slice of the propagation keys,
  # ship them back to the parent (across the fork via `Marshal`), and have the
  # parent merge them into one combined `@state`.
  #
  # Why a shared component (the state-side analog of {MongoIdPartitioner}): the
  # cursor-parallel path's "main productionization blocker" (notes, iter 11) is
  # exactly this distributed `@state`. Capturing per range and merging in range
  # order MUST yield the same arrays a single serial sorted cursor would have
  # captured — otherwise a child collection's `$in` scope would differ. Keeping
  # the capture/merge in one tested place (and DB-free testable, like the
  # partitioner) is what guarantees that invariant.
  class PropagationCapture
    # Per-key accumulators for `keys`, in the given key order. Every observed
    # document pushes one value per key, so all accumulators stay the same length
    # (= number of documents observed).
    def initialize(keys)
      @keys = keys
      @values = keys.each_with_object({}) { |key, acc| acc[key] = [] }
    end

    # Record one document: push each propagation key's value (nil if the document
    # lacks the key, matching the old `doc[key]` capture). Called once per
    # document in the hot streaming loop, so it does only this push — no
    # per-document allocation beyond growing the arrays.
    def observe(doc)
      @keys.each { |key| @values[key] << doc[key] }
      self
    end

    # The captured `{key => [values...]}` hash. This is what gets published into
    # the adapter's `@state[collection]`, and what a forked worker `Marshal.dump`s
    # for the parent to {merge}.
    def to_h
      @values
    end

    # Merge per-range captured hashes — produced by workers that each fetched a
    # disjoint `_id` range, given here IN RANGE ORDER — into one combined
    # `{key => [values...]}`. Concatenating in range order reproduces exactly the
    # array a single serial cursor sorted by `_id` would have captured, because
    # {MongoIdPartitioner}'s ranges are contiguous, disjoint, exhaustive and
    # ordered. `keys` is passed explicitly so the merged hash carries exactly the
    # expected key set regardless of what any individual capture contained.
    #
    # The captured hashes are plain Ruby Hashes (e.g. round-tripped through
    # `Marshal` across a fork); a missing key contributes nothing.
    def self.merge(keys, captured_in_order)
      keys.each_with_object({}) do |key, acc|
        acc[key] = captured_in_order.flat_map { |captured| captured[key] || [] }
      end
    end
  end
end
