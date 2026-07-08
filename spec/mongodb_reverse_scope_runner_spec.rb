# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "mongo"

require_relative "../script/database_config"

# End-to-end reverse_scope run through the mongodb adapter: a full Runner pass
# against a dedicated seeded database.
#
# Shape: `organizations` is the dump target. `articles` and `invitations` are
# organization-scoped and both point at the global-identity `accounts`
# collection (`author_account_id` / `invitee_account_id`). `accounts` declares
# `reverse_scope` over those two arms, and `account_profiles` is a satellite
# hanging off `accounts`. The run must:
#
#   - process the referencers BEFORE accounts (and accounts before its
#     satellite), which shows up in the insert-NNN file indexes,
#   - constrain accounts to the union of the ids the two (already scoped)
#     referencers actually point at — dropping null FKs and other tenants' ids,
#   - cascade that narrowing into the satellite through the ordinary captured
#     parent-id mechanism,
#   - keep masking behavior unchanged on the reverse-scoped collection.
module Exwiw
  RSpec.describe "mongodb reverse_scope export", :mongodb_reverse_scope do
    REVERSE_SCOPE_DB = "exwiw_reverse_scope_test"

    ORG1 = "0e0100000000000000000001"
    ORG2 = "0e0100000000000000000002"
    ACCOUNTS = {
      acc1: "0acc00000000000000000001", # org1: article author
      acc2: "0acc00000000000000000002", # org1: article author AND invitee
      acc3: "0acc00000000000000000003", # org1: invitee only
      acc4: "0acc00000000000000000004", # org2 only — must NOT be dumped
      acc5: "0acc00000000000000000005", # referenced by nothing — must NOT be dumped
    }.freeze

    def oid(hex)
      BSON::ObjectId.from_string(hex)
    end

    before(:all) do
      mongo = database_config("mongodb")
      host = "#{mongo.fetch(:host)}:#{mongo.fetch(:port)}"

      Mongo::Logger.logger.level = ::Logger::WARN
      client = Mongo::Client.new([host], database: REVERSE_SCOPE_DB)
      client.database.drop

      client["organizations"].insert_many([
        { "_id" => oid(ORG1), "name" => "Org 1" },
        { "_id" => oid(ORG2), "name" => "Org 2" },
      ])
      client["accounts"].insert_many(
        ACCOUNTS.map { |key, hex| { "_id" => oid(hex), "name" => "Account #{key}" } },
      )
      client["articles"].insert_many([
        { "_id" => oid("a"*1 + "0"*19 + "0001"), "organization_id" => oid(ORG1), "author_account_id" => oid(ACCOUNTS[:acc1]) },
        { "_id" => oid("a"*1 + "0"*19 + "0002"), "organization_id" => oid(ORG1), "author_account_id" => oid(ACCOUNTS[:acc2]) },
        # A null FK on an in-scope row must not leak a nil into the id union.
        { "_id" => oid("a"*1 + "0"*19 + "0003"), "organization_id" => oid(ORG1), "author_account_id" => nil },
        # Another tenant's referencer: its ids must not widen the dump.
        { "_id" => oid("a"*1 + "0"*19 + "0004"), "organization_id" => oid(ORG2), "author_account_id" => oid(ACCOUNTS[:acc4]) },
      ])
      client["invitations"].insert_many([
        { "_id" => oid("1"*4 + "0"*16 + "0001"), "organization_id" => oid(ORG1), "invitee_account_id" => oid(ACCOUNTS[:acc2]) },
        { "_id" => oid("1"*4 + "0"*16 + "0002"), "organization_id" => oid(ORG1), "invitee_account_id" => oid(ACCOUNTS[:acc3]) },
        { "_id" => oid("1"*4 + "0"*16 + "0003"), "organization_id" => oid(ORG2), "invitee_account_id" => oid(ACCOUNTS[:acc5]) },
      ])
      client["account_profiles"].insert_many(
        ACCOUNTS.map.with_index(1) do |(_, hex), i|
          { "_id" => oid("bb" + "0"*18 + i.to_s.rjust(4, "0")), "account_id" => oid(hex), "bio" => "bio #{i}" }
        end,
      )
      client.close
    end

    let(:schema_configs) do
      {
        "organizations" => {
          "name" => "organizations",
          "primary_key" => "_id",
          "belongs_tos" => [],
          "fields" => [{ "name" => "_id" }, { "name" => "name" }],
        },
        "articles" => {
          "name" => "articles",
          "primary_key" => "_id",
          "belongs_tos" => [{ "table_name" => "organizations", "foreign_key" => "organization_id" }],
          "fields" => [{ "name" => "_id" }, { "name" => "organization_id" }, { "name" => "author_account_id" }],
        },
        "invitations" => {
          "name" => "invitations",
          "primary_key" => "_id",
          "belongs_tos" => [{ "table_name" => "organizations", "foreign_key" => "organization_id" }],
          "fields" => [{ "name" => "_id" }, { "name" => "organization_id" }, { "name" => "invitee_account_id" }],
        },
        "accounts" => {
          "name" => "accounts",
          "primary_key" => "_id",
          # `comment` is a legitimate documentation key and must stay accepted.
          "comment" => "Global identity collection; scoped via reverse_scope.",
          "reverse_scope" => {
            "via" => [
              { "table" => "articles", "column" => "author_account_id" },
              { "table" => "invitations", "column" => "invitee_account_id" },
            ],
          },
          "belongs_tos" => [],
          "fields" => [{ "name" => "_id" }, { "name" => "name", "replace_with" => "masked{_id}" }],
        },
        "account_profiles" => {
          "name" => "account_profiles",
          "primary_key" => "_id",
          "belongs_tos" => [{ "table_name" => "accounts", "foreign_key" => "account_id" }],
          "fields" => [{ "name" => "_id" }, { "name" => "account_id" }, { "name" => "bio" }],
        },
      }
    end

    let(:connection_config) do
      mongo = database_config("mongodb")
      ConnectionConfig.new(
        adapter: "mongodb",
        database_name: REVERSE_SCOPE_DB,
        host: mongo.fetch(:host),
        port: mongo.fetch(:port).to_i,
        user: nil, password: nil,
      )
    end

    def run_export!(schema_dir, output_dir)
      schema_configs.each do |name, config|
        File.write(File.join(schema_dir, "#{name}.json"), JSON.pretty_generate(config))
      end
      Runner.new(
        connection_config: connection_config,
        output_dir: output_dir,
        schema_dir: schema_dir,
        dump_target: DumpTarget.new(table_name: "organizations", ids: [ORG1]),
        logger: ::Logger.new(nil),
      ).run
    end

    def dumped(output_dir, collection)
      path = Dir[File.join(output_dir, "insert-*-#{collection}.jsonl")].first
      return [nil, []] if path.nil?

      index = File.basename(path)[/insert-(\d+)-/, 1].to_i
      docs = File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
      [index, docs]
    end

    around do |ex|
      Dir.mktmpdir do |schema_dir|
        Dir.mktmpdir do |output_dir|
          @schema_dir = schema_dir
          @output_dir = output_dir
          ex.run
        end
      end
    end

    it "dumps the reverse-scoped collection after its referencers and narrows it to the union of their ids" do
      run_export!(@schema_dir, @output_dir)

      articles_idx, articles = dumped(@output_dir, "articles")
      invitations_idx, invitations = dumped(@output_dir, "invitations")
      accounts_idx, accounts = dumped(@output_dir, "accounts")
      profiles_idx, profiles = dumped(@output_dir, "account_profiles")

      # Ordering: every arm referencer before the reverse-scoped collection,
      # which in turn precedes its satellite.
      expect(articles_idx).to be < accounts_idx
      expect(invitations_idx).to be < accounts_idx
      expect(accounts_idx).to be < profiles_idx

      # The referencers themselves are scoped to org1 as usual.
      expect(articles.size).to eq(3)
      expect(invitations.size).to eq(2)

      # accounts = union(articles.author_account_id, invitations.invitee_account_id)
      # for org1 only: acc1 + acc2 (article authors, nil dropped) + acc2, acc3
      # (invitees, deduped). acc4 (other tenant) and acc5 (unreferenced) are out.
      expect(accounts.map { |d| d.dig("_id", "$oid") }).to contain_exactly(
        ACCOUNTS[:acc1], ACCOUNTS[:acc2], ACCOUNTS[:acc3],
      )

      # The satellite tightens to the kept accounts through the ordinary
      # captured-parent-id mechanism — no config of its own.
      expect(profiles.map { |d| d.dig("account_id", "$oid") }).to contain_exactly(
        ACCOUNTS[:acc1], ACCOUNTS[:acc2], ACCOUNTS[:acc3],
      )
    end

    it "keeps masking behavior unchanged on the reverse-scoped collection" do
      run_export!(@schema_dir, @output_dir)

      _, accounts = dumped(@output_dir, "accounts")
      expect(accounts.map { |d| d["name"] }).to contain_exactly(
        "masked#{ACCOUNTS[:acc1]}", "masked#{ACCOUNTS[:acc2]}", "masked#{ACCOUNTS[:acc3]}",
      )
    end
  end
end
