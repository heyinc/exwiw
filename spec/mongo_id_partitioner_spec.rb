# frozen_string_literal: true

require "spec_helper"

module Exwiw
  RSpec.describe MongoIdPartitioner do
    # Verify a set of `[lo, hi]` ranges tiles `ids` exactly: contiguous, disjoint,
    # exhaustive, and ascending. This is the byte-identity invariant a
    # cursor-parallel dump depends on (each range becomes one worker's cursor, and
    # the parts are concatenated in range order to equal the serial sorted dump).
    def assert_tiles(ids, ranges)
      index = ids.each_with_index.to_h # id => index
      covered = []
      ranges.each do |lo, hi|
        lo_i = index.fetch(lo)
        hi_i = index.fetch(hi)
        expect(lo_i).to be <= hi_i, "range [#{lo}, #{hi}] is descending"
        covered.concat((lo_i..hi_i).to_a)
      end
      expect(covered).to eq((0...ids.size).to_a),
                         "ranges #{ranges.inspect} do not tile #{ids.size} ids exactly"
    end

    describe ".ranges_from_sorted_ids" do
      it "returns [] for an empty id list" do
        expect(described_class.ranges_from_sorted_ids([], 4)).to eq([])
      end

      it "returns a single inclusive range covering everything for workers = 1" do
        expect(described_class.ranges_from_sorted_ids((1..10).to_a, 1)).to eq([[1, 10]])
      end

      it "matches the probe's exact partitioning for known cases" do
        ids = (1..10).to_a
        expect(described_class.ranges_from_sorted_ids(ids, 3)).to eq([[1, 4], [5, 8], [9, 10]])
        expect(described_class.ranges_from_sorted_ids(ids, 4)).to eq([[1, 3], [4, 6], [7, 9], [10, 10]])
        expect(described_class.ranges_from_sorted_ids(ids, 10)).to eq((1..10).map { |i| [i, i] })
      end

      it "never emits an empty range and never more than `workers` ranges" do
        (1..40).each do |n|
          ids = (1..n).to_a
          [1, 2, 3, 4, 8, 16].each do |workers|
            ranges = described_class.ranges_from_sorted_ids(ids, workers)
            expect(ranges.size).to be <= workers, "n=#{n} workers=#{workers}"
            descending = ranges.any? { |lo, hi| ids.index(lo) > ids.index(hi) }
            expect(descending).to be(false), "n=#{n} workers=#{workers} produced a descending range"
          end
        end
      end

      it "produces contiguous, disjoint, exhaustive, ascending ranges for all sizes" do
        [3, 10, 17, 100, 1000].each do |n|
          ids = (0...n).map { |i| i * 3 + 1 } # non-contiguous, still sorted & unique
          [1, 2, 3, 5, 8, 13, n].each do |workers|
            assert_tiles(ids, described_class.ranges_from_sorted_ids(ids, workers))
          end
        end
      end

      it "yields at most one range per id when workers exceeds the id count" do
        ids = %w[a b c]
        expect(described_class.ranges_from_sorted_ids(ids, 8)).to eq([%w[a a], %w[b b], %w[c c]])
      end

      it "raises for a non-positive worker count" do
        expect { described_class.ranges_from_sorted_ids((1..5).to_a, 0) }
          .to raise_error(ArgumentError, /workers must be >= 1/)
      end
    end

    describe ".range_filter" do
      it "merges inclusive $gte/$lte bounds onto the base filter without mutating it" do
        base = { "shop_id" => 42 }
        filter = described_class.range_filter(base, "_id", 100, 200)
        expect(filter).to eq("shop_id" => 42, "_id" => { "$gte" => 100, "$lte" => 200 })
        expect(base).to eq("shop_id" => 42)
      end
    end

    describe ".ranges_for" do
      # Minimal stand-in for a Mongo::Collection::View: records the index-only
      # projection/sort the partitioner applies and yields `{primary_key => id}`
      # docs, so the DB-backed wrapper can be tested without a live MongoDB.
      class FakeView
        attr_reader :projection_spec, :sort_spec

        def initialize(ids)
          @ids = ids
        end

        def projection(spec)
          @projection_spec = spec
          self
        end

        def sort(spec)
          @sort_spec = spec
          self
        end

        def map(&block)
          @ids.map { |id| block.call("_id" => id) }
        end
      end

      it "scans index-only and delegates to the pure split" do
        view = FakeView.new((1..10).to_a)
        ranges = described_class.ranges_for(view, "_id", 3)

        expect(view.projection_spec).to eq("_id" => 1)
        expect(view.sort_spec).to eq("_id" => 1)
        expect(ranges).to eq(described_class.ranges_from_sorted_ids((1..10).to_a, 3))
      end

      it "returns [] when the view matches nothing" do
        expect(described_class.ranges_for(FakeView.new([]), "_id", 4)).to eq([])
      end
    end
  end
end
