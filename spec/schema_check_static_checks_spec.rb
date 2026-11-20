# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

module Exwiw
  # The static checks (`check:`) of SchemaCheck. The regenerator leaves the copy as it is, so the committed config
  # never drifts and the report holds only what the checks find.
  RSpec.describe SchemaCheck, "static checks" do
    let(:schema_dir) { @schema_dir }
    let(:profiles) { [] }

    around do |example|
      Dir.mktmpdir do |dir|
        @schema_dir = dir
        example.run
      end
    end

    def write(name, hash, dir: schema_dir)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "#{name}.json"), JSON.pretty_generate(hash) + "\n")
    end

    def table(name, columns, **extra)
      { "name" => name, "primary_key" => "id", "belongs_tos" => [], "columns" => columns }.merge(extra.transform_keys(&:to_s))
    end

    def collection(name, fields, **extra)
      { "name" => name, "primary_key" => "_id", "belongs_tos" => [], "fields" => fields }.merge(extra.transform_keys(&:to_s))
    end

    def checks(value)
      CheckConfig.parse(value, profiles: profiles)
    end

    def report(check: { "integrity" => true, "credentials" => true, "masks" => true }, adapter: "sqlite", config_class: TableConfig)
      described_class.new(
        schema_dir: schema_dir, regenerator: ->(_dir) {}, profiles: profiles, config_class: config_class,
        checks: check.is_a?(CheckConfig) ? check : checks(check), adapter: adapter,
      ).run
    end

    it "reports nothing for a config whose masks are all in order" do
      write("users", table("users", [
                             { "name" => "id" },
                             { "name" => "email", "replace_with" => "user{id}@example.com" },
                             { "name" => "api_token", "raw_sql" => "hex(randomblob(16))" },
                             { "name" => "phone", "allow_unmasked" => true },
                             { "name" => "nickname" },
                           ]))

      expect(report.slice("integrity", "credentials", "masks")).to eq("integrity" => [], "credentials" => [], "masks" => [])
      expect(described_class.clean?(report)).to be(true)
    end

    describe "which checks run" do
      before { write("users", table("users", [{ "name" => "id" }, { "name" => "email" }])) }

      it "runs only integrity by default" do
        result = report(check: CheckConfig.default)

        expect(result).to include("integrity" => [])
        expect(result).not_to have_key("credentials")
        expect(result).not_to have_key("masks")
      end

      it "adds no key for a disabled check" do
        expect(report(check: { "integrity" => false })).not_to have_key("integrity")
      end
    end

    describe "integrity" do
      let(:only_integrity) { { "integrity" => true } }

      it "reports a masked primary key" do
        write("users", table("users", [{ "name" => "id", "raw_sql" => "NULL" }, { "name" => "email", "replace_with" => "x" }]))

        expect(report(check: only_integrity)["integrity"])
          .to eq(["users.id [base]: the primary key is masked, but mask-update addresses rows by it; remove the mask"])
      end

      it "reports a masked table that does not select its primary key" do
        write("users", table("users", [{ "name" => "id", "ignore" => true }, { "name" => "email", "replace_with" => "x" }]))

        expect(report(check: only_integrity)["integrity"]).to eq(
          ["users.id [base]: the table declares masks but does not select its primary key (is it ignored?), so mask-update cannot address its rows"],
        )
      end

      it "does not report a table that declares no mask, which only fails when someone masks it" do
        write("users", table("users", [{ "name" => "id", "ignore" => true }, { "name" => "email" }]))

        expect(report(check: only_integrity)["integrity"]).to eq([])
      end

      it "reports an allow_guessable_credential that guards nothing" do
        write("users", table("users", [
                               { "name" => "id" },
                               { "name" => "api_token", "raw_sql" => "NULL", "allow_guessable_credential" => true },
                               { "name" => "city", "replace_with" => "x", "allow_guessable_credential" => true },
                               { "name" => "secret", "allow_guessable_credential" => true },
                               { "name" => "password", "replace_with" => "x", "allow_guessable_credential" => true },
                             ]))

        expect(report(check: only_integrity)["integrity"]).to eq(%w[api_token city secret].map do |column|
          "users.#{column} [base]: sets allow_guessable_credential, but is not a credential-looking column " \
            "masked to a guessable value; remove it"
        end)
      end

      it "reports an allow_unmasked that allows nothing, saying why" do
        write("users", table("users", [
                               { "name" => "id", "allow_unmasked" => true },
                               { "name" => "shop_id", "allow_unmasked" => true },
                               { "name" => "email", "replace_with" => "x", "allow_unmasked" => true },
                               { "name" => "nickname", "allow_unmasked" => true },
                               { "name" => "phone", "allow_unmasked" => true },
                             ], belongs_tos: [{ "foreign_key" => "shop_id", "table_name" => "shops" }]))
        write("shops", table("shops", [{ "name" => "id" }]))

        expect(report(check: only_integrity)["integrity"]).to eq([
          "users.email [base]: sets allow_unmasked, but it is masked; remove it",
          "users.id [base]: sets allow_unmasked, but it is the primary key or a belongs_to foreign key, which are never masked; remove it",
          "users.nickname [base]: sets allow_unmasked, but its name matches no mask pattern; remove it",
          "users.shop_id [base]: sets allow_unmasked, but it is the primary key or a belongs_to foreign key, which are never masked; remove it",
        ])
      end

      it "counts the configured patterns when judging allow_unmasked" do
        write("users", table("users", [{ "name" => "id" }, { "name" => "name_kana", "allow_unmasked" => true }]))

        expect(report(check: { "masks" => { "patterns" => ["(^|_)kana(_|$)"] } })["integrity"]).to eq([])
        expect(report(check: only_integrity)["integrity"].join).to include("users.name_kana [base]: sets allow_unmasked")
      end
    end

    describe "credentials" do
      let(:only_credentials) { { "integrity" => false, "credentials" => true } }

      it "reports a credential-looking column masked to a guessable value, unless it allows that" do
        write("accounts", table("accounts", [
                                  { "name" => "id" },
                                  { "name" => "api_token", "replace_with" => "token-{id}" },
                                  { "name" => "password_digest", "map" => "->(_) { 'x' }" },
                                  { "name" => "session_secret", "replace_with" => "KNOWN", "allow_guessable_credential" => true },
                                  { "name" => "access_key", "raw_sql" => "NULL" },
                                  { "name" => "reset_token", "raw_sql" => "lower(hex(randomblob(16)))" },
                                  { "name" => "salt" },
                                ]))

        expect(report(check: only_credentials)["credentials"]).to eq(%w[api_token password_digest].map do |column|
          "accounts.#{column} [base]: masked to a guessable value; mask it with raw_sql \"NULL\" or a random expression, " \
            "or set allow_guessable_credential"
        end)
      end

      it "judges the random expression by the adapter's own functions" do
        write("accounts", table("accounts", [{ "name" => "id" }, { "name" => "api_token", "raw_sql" => "gen_random_uuid()::text" }]))

        expect(report(check: only_credentials, adapter: "postgresql")["credentials"]).to eq([])
        expect(report(check: only_credentials, adapter: "sqlite")["credentials"].size).to eq(1)
      end
    end

    describe "masks" do
      let(:only_masks) { { "integrity" => false, "masks" => true } }

      it "reports an unmasked column whose name looks sensitive" do
        write("users", table("users", [
                               { "name" => "id" },
                               { "name" => "email" },
                               { "name" => "billing_address", "raw_sql" => "NULL" },
                               { "name" => "phone_number", "allow_unmasked" => true },
                               { "name" => "birthday", "ignore" => true },
                               { "name" => "nickname" },
                             ]))

        expect(report(check: only_masks)["masks"]).to eq(
          ["users.email [base]: looks sensitive but is not masked; add a mask, or set allow_unmasked if the real value is needed"],
        )
      end

      it "exempts the primary key and belongs_to foreign keys" do
        write("users", table("users", [{ "name" => "id" }, { "name" => "address_id" }], primary_key: "id",
                                                                                      belongs_tos: [{ "foreign_key" => "address_id", "table_name" => "addresses" }]))
        write("addresses", table("addresses", [{ "name" => "id" }, { "name" => "city" }]))
        write("emails", table("emails", [{ "name" => "email" }, { "name" => "body", "raw_sql" => "NULL" }], primary_key: "email"))

        expect(report(check: only_masks)["masks"]).to eq([])
      end

      it "adds the configured patterns to the defaults" do
        write("users", table("users", [{ "name" => "id" }, { "name" => "email" }, { "name" => "name_kana" }]))

        result = report(check: { "integrity" => false, "masks" => { "patterns" => ["(^|_)kana(_|$)"] } })
        expect(result["masks"].map { |entry| entry[/\A\S+/] }).to eq(%w[users.email users.name_kana])
      end
    end

    describe "tables the checks skip" do
      it "skips ignored, rails-managed and composite-key tables, as mask-update refuses them" do
        write("ignored", table("ignored", [{ "name" => "id", "raw_sql" => "NULL" }, { "name" => "email" }], ignore: true))
        write("schema_migrations", { "name" => "schema_migrations", "type" => TableConfig::RAILS_MANAGED_SCHEMA_MIGRATIONS })
        write("pairs", table("pairs", [{ "name" => "email" }], primary_key: nil, ignore: true,
                                                               type: TableConfig::UNSUPPORTED_COMPOSITE_PRIMARY_KEY))

        expect(report.slice("integrity", "credentials", "masks")).to eq("integrity" => [], "credentials" => [], "masks" => [])
      end
    end

    describe "MongoDB" do
      def mongo_report(check)
        report(check: check, adapter: "mongodb", config_class: MongodbCollectionConfig)
      end

      before do
        write("users", collection("users", [
                                    { "name" => "_id" },
                                    { "name" => "email" },
                                    { "name" => "api_token", "replace_with" => "x" },
                                    { "name" => "nickname", "allow_guessable_credential" => true },
                                  ]))
        write("addresses", collection("addresses", [
                                        { "name" => "_id" },
                                        { "name" => "zip_code" },
                                        { "name" => "secret", "replace_with" => "x" },
                                        { "name" => "city", "allow_unmasked" => true },
                                      ], embedded_in: { "collection_name" => "users", "path" => "profile.addresses" }))
      end

      it "reports through the parent, under the embedded field's path" do
        result = mongo_report({ "integrity" => true, "credentials" => true, "masks" => true })

        expect(result["masks"].map { |entry| entry[/\A\S+/] }).to eq(%w[users.email users.profile.addresses.zip_code])
        expect(result["credentials"]).to eq(%w[users.api_token users.profile.addresses.secret].map do |path|
          "#{path} [base]: masked to a guessable value, and a MongoDB mask cannot be NULL or random; " \
            "set allow_guessable_credential, or ignore the field"
        end)
        expect(result["integrity"]).to eq([
          "users.nickname [base]: sets allow_guessable_credential, but is not a credential-looking column masked to a guessable value; remove it",
          "users.profile.addresses.city [base]: sets allow_unmasked, but its name matches no mask pattern; remove it",
        ])
      end

      it "accepts a guessable credential that allows it, and a sensitive field that allows being unmasked" do
        write("users", collection("users", [
                                    { "name" => "_id" },
                                    { "name" => "email", "allow_unmasked" => true },
                                    { "name" => "api_token", "replace_with" => "x", "allow_guessable_credential" => true },
                                  ]))
        write("addresses", collection("addresses", [{ "name" => "_id" }, { "name" => "zip_code", "replace_with" => "000" }],
                                      embedded_in: { "collection_name" => "users", "path" => "addresses" }))

        result = mongo_report({ "integrity" => true, "credentials" => true, "masks" => true })
        expect(result.slice("integrity", "credentials", "masks")).to eq("integrity" => [], "credentials" => [], "masks" => [])
      end

      it "reports a masked _id" do
        write("users", collection("users", [{ "name" => "_id", "replace_with" => "x" }]))
        File.delete(File.join(schema_dir, "addresses.json"))

        expect(mongo_report({ "integrity" => true })["integrity"])
          .to eq(["users._id [base]: the primary key is masked, but mask-update addresses rows by it; remove the mask"])
      end
    end

    describe "profiles" do
      let(:profiles) { %w[dev ci] }

      before do
        write("users", table("users", [{ "name" => "id" }, { "name" => "email" }, { "name" => "phone" }]))
        File.write(File.join(schema_dir, "users.dev.json"), JSON.generate(
                                                              "name" => "users", "columns" => [{ "name" => "phone", "replace_with" => "000" }],
                                                            ))
      end

      it "lists a finding once with every profile it occurs in" do
        expect(report(check: { "masks" => true })["masks"].map { |entry| entry[/\A[^:]+/] })
          .to eq(["users.email [base, dev, ci]", "users.phone [base, ci]"])
      end

      it "runs a check against the selected profiles only" do
        expect(report(check: { "masks" => { "profiles" => %w[dev] } })["masks"].map { |entry| entry[/\A[^:]+/] })
          .to eq(["users.email [dev]"])
      end

      it "lets an overlay un-mask a column with allow_unmasked, dropping the base mask" do
        write("users", table("users", [{ "name" => "id" }, { "name" => "email", "replace_with" => "x" }]))
        File.write(File.join(schema_dir, "users.dev.json"), JSON.generate(
                                                              "name" => "users", "columns" => [{ "name" => "email", "allow_unmasked" => true }],
                                                            ))

        result = report
        expect(result["masks"]).to eq([])
        expect(result["integrity"]).to eq([])
      end
    end

    describe "databases" do
      it "labels each finding with its database directory and judges it with that database's adapter" do
        write("accounts", table("accounts", [{ "name" => "id" }, { "name" => "api_token", "raw_sql" => "gen_random_uuid()::text" }]),
              dir: File.join(schema_dir, "primary"))
        write("accounts", table("accounts", [{ "name" => "id" }, { "name" => "api_token", "raw_sql" => "gen_random_uuid()::text" }]),
              dir: File.join(schema_dir, "legacy"))
        adapters = { "primary" => "postgresql", "legacy" => "mysql" }

        result = report(check: { "credentials" => true }, adapter: ->(database) { adapters.fetch(database) })
        expect(result["credentials"].map { |entry| entry[/\A\S+/] }).to eq(%w[legacy/accounts.api_token])
      end

      it "fails loudly when the adapter is unknown" do
        write("users", table("users", [{ "name" => "id" }]))

        expect { report(adapter: nil) }.to raise_error(ArgumentError, /needs the database adapter to run the integrity, credentials, masks check/)
        expect { report(adapter: "oracle") }.to raise_error(ArgumentError, /cannot resolve the adapter of the schema directory: Unsupported adapter/)
      end

      it "fails when the configs are not the adapter's kind" do
        write("users", table("users", [{ "name" => "id" }]))

        expect { report(adapter: "mongodb") }.to raise_error(ArgumentError, /was loaded as Exwiw::TableConfig/)
      end
    end

    describe ".clean? and --fail-on=stale" do
      it "is not clean with a finding, which is not stale drift" do
        write("users", table("users", [{ "name" => "id" }, { "name" => "email" }]))
        result = report

        expect(described_class.clean?(result)).to be(false)
        expect(described_class.stale?(result)).to be(false)
        expect(described_class.drifted?(result)).to be(false)
        expect(described_class.failed_checks(result)).to eq(%w[masks])
      end
    end
  end
end
