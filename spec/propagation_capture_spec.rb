# frozen_string_literal: true

require "spec_helper"
require "bson"

module Exwiw
  RSpec.describe PropagationCapture do
    describe "#observe / #to_h" do
      it "captures one value per key per document, in document order" do
        capture = described_class.new(%w[_id shop_id])
        capture.observe("_id" => 1, "shop_id" => 10)
        capture.observe("_id" => 2, "shop_id" => 20)

        expect(capture.to_h).to eq("_id" => [1, 2], "shop_id" => [10, 20])
      end

      it "captures nil for a document missing a key (matching doc[key])" do
        capture = described_class.new(%w[_id uuid])
        capture.observe("_id" => 1) # no uuid

        expect(capture.to_h).to eq("_id" => [1], "uuid" => [nil])
      end

      it "returns an empty per-key hash when nothing is observed" do
        expect(described_class.new(%w[_id shop_id]).to_h).to eq("_id" => [], "shop_id" => [])
      end

      it "returns {} for no keys" do
        expect(described_class.new([]).to_h).to eq({})
      end

      it "returns self from #observe so it can be chained" do
        capture = described_class.new(%w[_id])
        expect(capture.observe("_id" => 1)).to be(capture)
      end
    end

    describe ".merge" do
      it "concatenates per-range captures in range order, per key" do
        r1 = { "_id" => [1, 2], "shop_id" => [10, 10] }
        r2 = { "_id" => [3, 4], "shop_id" => [20, 20] }

        expect(described_class.merge(%w[_id shop_id], [r1, r2]))
          .to eq("_id" => [1, 2, 3, 4], "shop_id" => [10, 10, 20, 20])
      end

      it "reproduces exactly a single serial capture over the concatenated documents" do
        docs = (1..10).map { |i| { "_id" => i, "shop_id" => (i <= 5 ? 100 : 200) } }
        keys = %w[_id shop_id]

        serial = described_class.new(keys)
        docs.each { |d| serial.observe(d) }

        # Split docs into three contiguous ranges, capture each independently, and
        # merge in range order — the cursor-parallel path's capture model.
        ranges = [docs[0...4], docs[4...7], docs[7..]]
        per_range = ranges.map do |slice|
          c = described_class.new(keys)
          slice.each { |d| c.observe(d) }
          c.to_h
        end

        expect(described_class.merge(keys, per_range)).to eq(serial.to_h)
      end

      it "yields the declared key set even when a capture omits a key" do
        # A capture round-tripped through Marshal could in principle lack a key;
        # merge fills it from `keys` and treats a missing key as empty.
        expect(described_class.merge(%w[_id uuid], [{ "_id" => [1] }]))
          .to eq("_id" => [1], "uuid" => [])
      end

      it "returns an empty hash for no captures" do
        expect(described_class.merge(%w[_id], [])).to eq("_id" => [])
      end
    end

    describe "cross-process IPC viability (Marshal round-trip)" do
      # A forked cursor-parallel worker captures its range's propagation keys and
      # ships the hash back to the parent via Marshal. Propagation values are the
      # FK field values actually stored in Mongo — most importantly
      # BSON::ObjectId, plus Integer/String — so they must survive Marshal
      # unchanged, or the merged $in scope would diverge.
      it "preserves BSON::ObjectId, Integer and String values through Marshal" do
        oid_a = BSON::ObjectId.new
        oid_b = BSON::ObjectId.new
        capture = described_class.new(%w[_id legacy_id uuid])
        capture.observe("_id" => oid_a, "legacy_id" => 1, "uuid" => "u-1")
        capture.observe("_id" => oid_b, "legacy_id" => 2, "uuid" => "u-2")

        round_tripped = Marshal.load(Marshal.dump(capture.to_h))

        expect(round_tripped).to eq(capture.to_h)
        expect(round_tripped["_id"]).to eq([oid_a, oid_b])
        expect(round_tripped["_id"].first).to be_a(BSON::ObjectId)
      end

      it "merges Marshal-round-tripped per-worker captures back to the serial result" do
        oids = Array.new(6) { BSON::ObjectId.new }
        docs = oids.each_with_index.map { |oid, i| { "_id" => oid, "shop_id" => oids.first } }
        keys = %w[_id shop_id]

        serial = described_class.new(keys)
        docs.each { |d| serial.observe(d) }

        per_worker = [docs[0...3], docs[3..]].map do |slice|
          c = described_class.new(keys)
          slice.each { |d| c.observe(d) }
          Marshal.load(Marshal.dump(c.to_h)) # cross-fork transport
        end

        expect(described_class.merge(keys, per_worker)).to eq(serial.to_h)
      end
    end
  end
end
