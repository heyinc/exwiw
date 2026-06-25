# frozen_string_literal: true

require "spec_helper"

RSpec.describe Exwiw::MongodbParallelDumper do
  describe ".bin_pack (LPT)" do
    it "places the single heaviest item alone when it dominates the rest" do
      items = %w[heavy a b c d]
      weights = { "heavy" => 100, "a" => 1, "b" => 1, "c" => 1, "d" => 1 }

      groups = described_class.bin_pack(items, 2) { |name| weights.fetch(name) }

      heavy_group = groups.find { |g| g.include?("heavy") }
      expect(heavy_group).to eq(["heavy"])
    end

    it "partitions every item exactly once across the bins" do
      items = (1..20).map { |i| "c#{i}" }
      weights = items.each_with_index.to_h { |name, i| [name, (i * 7) % 11] }

      groups = described_class.bin_pack(items, 4) { |name| weights.fetch(name) }

      expect(groups.flatten.sort).to eq(items.sort)
      expect(groups.size).to eq(4)
    end

    it "balances load greedily (heaviest-first onto least-loaded)" do
      items = %w[a b c d]
      weights = { "a" => 5, "b" => 4, "c" => 3, "d" => 2 }

      groups = described_class.bin_pack(items, 2) { |name| weights.fetch(name) }

      loads = groups.map { |g| g.sum { |name| weights.fetch(name) } }
      # LPT on [5,4,3,2]: 5->bin0, 4->bin1, 3->bin1(=4)... actually 3->bin0(=5)? bin1=4<5 so 3->bin1=7; 2->bin0=7 -> {5,2}/{4,3}=7/7
      expect(loads.sort).to eq([7, 7])
    end

    it "calls the weight block exactly once per item (weights may be DB-backed)" do
      items = %w[a b c]
      calls = Hash.new(0)

      described_class.bin_pack(items, 2) { |name| calls[name] += 1; 1 }

      expect(calls).to eq({ "a" => 1, "b" => 1, "c" => 1 })
    end

    it "yields empty bins when there are fewer items than bins" do
      groups = described_class.bin_pack(%w[only], 3) { 1 }

      expect(groups.size).to eq(3)
      expect(groups.flatten).to eq(["only"])
      expect(groups.count(&:empty?)).to eq(2)
    end

    it "rejects a non-positive bin count" do
      expect { described_class.bin_pack(%w[a], 0) { 1 } }.to raise_error(ArgumentError, /bins must be/)
    end
  end

  describe ".available?" do
    it "is true on a fork-capable runtime" do
      expect(described_class.available?).to eq(Process.respond_to?(:fork))
    end
  end
end
