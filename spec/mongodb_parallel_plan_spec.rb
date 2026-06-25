# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Exwiw::MongodbParallelPlan do
  # Build a MongodbCollectionConfig from a compact spec. `belongs_to` is a list
  # of parent collection names (each becomes `<name>_id` -> <name>).
  def collection(name, belongs_to: [], ignore: false, embedded_in: nil)
    hash = {
      "name" => name,
      "primary_key" => "_id",
      "belongs_tos" => belongs_to.map { |parent| { "foreign_key" => "#{parent}_id", "table_name" => parent } },
      "fields" => [],
    }
    hash["ignore"] = true if ignore
    hash["embedded_in"] = { "collection_name" => embedded_in, "path" => name } if embedded_in
    Exwiw::MongodbCollectionConfig.from(hash).reject_ignored_members!
  end

  # A representative graph exercising every group and edge:
  #
  #   entities (TARGET, no belongs_to)
  #     ^                     leaves: owners (referenced), categories (referenced)
  #   stores -> entities, owners(leaf)        unreferenced_leaf (referenced by no one)
  #     ^
  #   items  -> stores
  #
  #   ref_bt: audit_logs -> categories(leaf)     (not reachable to target)
  #           audit_details -> audit_logs        (-> one 2-member component)
  #           orphan_ref -> unreferenced_ref(leaf) (-> its own 1-member component)
  #
  #   legacy (ignore:true)   profiles (embedded_in entities)
  let(:configs) do
    [
      collection("entities"),
      collection("stores", belongs_to: %w[entities owners]),
      collection("items", belongs_to: %w[stores]),
      collection("owners"),
      collection("categories"),
      collection("unreferenced_leaf"),
      collection("unreferenced_ref"),
      collection("audit_logs", belongs_to: %w[categories]),
      collection("audit_details", belongs_to: %w[audit_logs]),
      collection("orphan_ref", belongs_to: %w[unreferenced_ref]),
      collection("legacy", ignore: true),
      collection("profiles", embedded_in: "entities"),
    ]
  end

  subject(:plan) { described_class.new(configs: configs, target_table_name: "entities") }

  it "places reachable collections (including the target) in genuine" do
    expect(plan.genuine).to contain_exactly("entities", "stores", "items")
  end

  it "places belongs_to-free, unreachable collections in leaves" do
    expect(plan.leaves).to contain_exactly("owners", "categories", "unreferenced_leaf", "unreferenced_ref")
  end

  it "places collections with belongs_to that cannot reach the target in ref_bt" do
    expect(plan.ref_bt).to contain_exactly("audit_logs", "audit_details", "orphan_ref")
  end

  it "never classifies the target as a leaf even though it has no belongs_to" do
    expect(plan.leaves).not_to include("entities")
    expect(plan.genuine).to include("entities")
  end

  it "partitions the extractable collections exactly across the three groups" do
    expect((plan.genuine + plan.leaves + plan.ref_bt).sort).to eq(plan.extractable.sort)
    expect(plan.genuine & plan.leaves).to be_empty
    expect(plan.genuine & plan.ref_bt).to be_empty
    expect(plan.leaves & plan.ref_bt).to be_empty
  end

  it "excludes ignore:true collections from extraction but keeps them in the file ordering" do
    expect(plan.extractable).not_to include("legacy")
    expect(plan.ordered_all).to include("legacy")
    expect(plan.index_of).to have_key("legacy")
  end

  it "excludes embedded collections from the ordering entirely" do
    expect(plan.ordered_all).not_to include("profiles")
  end

  it "numbers the file index as a contiguous permutation over ordered_all" do
    expect(plan.index_of.values.sort).to eq((0...plan.ordered_all.size).to_a)
  end

  it "marks only the leaves referenced by a non-leaf collection as consumed" do
    # owners <- stores (genuine); categories <- audit_logs (ref_bt);
    # unreferenced_ref <- orphan_ref (ref_bt). unreferenced_leaf is referenced
    # by no one, so it needs no @state sidecar.
    expect(plan.consumed_leaves).to contain_exactly("owners", "categories", "unreferenced_ref")
  end

  it "seeds the cascade with genuine collections that directly reference a leaf" do
    expect(plan.direct_leaf_genuine).to contain_exactly("stores")
  end

  it "builds genuine-child adjacency keyed only by reachable parents" do
    expect(plan.genuine_children["entities"]).to contain_exactly("stores")
    expect(plan.genuine_children["stores"]).to contain_exactly("items")
    # owners is a leaf (not reachable), so stores is not registered under it.
    expect(plan.genuine_children["owners"]).to be_empty
  end

  it "groups ref_bt into dependency-closed, topo-ordered components" do
    by_size = plan.reference_components.sort_by(&:size)
    expect(by_size.map(&:size)).to eq([1, 2])
    expect(by_size[0]).to eq(["orphan_ref"])
    # audit_logs has no intra-ref_bt parent (its parent is the leaf categories),
    # so it is ordered before its child audit_details.
    expect(by_size[1]).to eq(["audit_logs", "audit_details"])
  end

  it "covers exactly the ref_bt collections across all components" do
    expect(plan.reference_components.flatten.sort).to eq(plan.ref_bt.sort)
  end
end
