# frozen_string_literal: true

require "spec_helper"
require "mongo"

require_relative "../script/mongoid_models"

# Round-trip scenario: exwiw's *dumped output* must be loadable by a real
# Mongoid application.
#
# We take the committed `insert_output_snapshots/mongodb/*.jsonl` (exwiw's
# masked dump of the shop-1 slice, in MongoDB Extended JSON), import them into a
# dedicated database, and then read every collection back through the
# `MongoidDummy` models — proving the documents exwiw emits (ObjectId `_id`s,
# embedded `posts`, masked fields, foreign keys) deserialize cleanly into the
# ORM and that associations resolve.
module Exwiw
  RSpec.describe "mongoid reads exwiw's dumped output", :mongoid_read_scenario do
    SNAPSHOT_DIR = File.expand_path("insert_output_snapshots/mongodb", __dir__)
    READ_SCENARIO_DB = "exwiw_mongoid_read_scenario"

    before(:all) do
      mongo = database_config("mongodb")
      host = "#{mongo.fetch(:host)}:#{mongo.fetch(:port)}"

      # Point the MongoidDummy models at a dedicated database and import the
      # dumped jsonl. ExtJSON.parse restores `$oid` to BSON::ObjectId so the
      # documents land with the same ObjectId `_id`s Mongoid expects by default.
      Mongo::Logger.logger.level = ::Logger::WARN
      Mongoid.configure do |config|
        config.clients.default = { hosts: [host], database: READ_SCENARIO_DB }
      end

      client = Mongo::Client.new([host], database: READ_SCENARIO_DB)
      client.database.drop
      Dir.glob(File.join(SNAPSHOT_DIR, "insert-*.jsonl")).sort.each do |path|
        collection = File.basename(path, ".jsonl").sub(/\Ainsert-\d+-/, "")
        docs = File.readlines(path, chomp: true).reject(&:empty?).map { |line| BSON::ExtJSON.parse(line) }
        client[collection].insert_many(docs) unless docs.empty?
      end
      client.close
    end

    it "reads top-level collections with the dumped counts" do
      expect(MongoidDummy::Shop.count).to eq(1)
      expect(MongoidDummy::User.count).to eq(2)
      expect(MongoidDummy::Product.count).to eq(3)
      expect(MongoidDummy::Order.count).to eq(6)
      expect(MongoidDummy::OrderItem.count).to eq(6)
      expect(MongoidDummy::Transaction.count).to eq(6)
      expect(MongoidDummy::SystemAnnouncement.count).to eq(3)
    end

    it "loads a document with its ObjectId _id intact" do
      shop = MongoidDummy::Shop.first
      expect(shop._id).to be_a(BSON::ObjectId)
      expect(shop.name).to eq("Shop 1")
    end

    it "reads exwiw's masked fields as ordinary attributes" do
      user = MongoidDummy::User.find(BSON::ObjectId.from_string("b00200000000000000000001"))
      # `replace_with: "masked{_id}@example.com"` produced the ObjectId hex.
      expect(user.name).to eq("maskedb00200000000000000000001")
      expect(user.email).to eq("maskedb00200000000000000000001@example.com")
    end

    it "deserializes the dumped embedded posts into Mongoid embedded documents" do
      user = MongoidDummy::User.find(BSON::ObjectId.from_string("b00200000000000000000001"))
      expect(user.posts).to all(be_a(MongoidDummy::Post))
      expect(user.posts.map(&:_id)).to all(be_a(BSON::ObjectId))
      expect(user.posts.map(&:title)).to eq(
        ["masked-title-b00800000000000000000065", "masked-title-b00800000000000000000066"],
      )
    end

    it "resolves belongs_to associations across the dumped collections" do
      order = MongoidDummy::Order.first
      expect(order.shop).to eq(MongoidDummy::Shop.first)
      expect(order.user).to be_a(MongoidDummy::User)
      expect(order.user.email).to start_with("masked")

      item = MongoidDummy::OrderItem.first
      expect(item.order).to be_a(MongoidDummy::Order)
      expect(item.product).to be_a(MongoidDummy::Product)

      expect(MongoidDummy::Transaction.first.order).to be_a(MongoidDummy::Order)
    end
  end
end
