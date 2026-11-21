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

    let(:guessable_reason) do
      "masked to a guessable value; mask it with unset or replace_with_random, or set allow_guessable_credential"
    end

    def report(check: { "integrity" => true, "guessable_credentials" => true, "unmasked_sensitive" => true }, adapter: "sqlite", config_class: TableConfig)
      described_class.new(
        schema_dir: schema_dir, regenerator: ->(_dir) {}, profiles: profiles, config_class: config_class,
        checks: check.is_a?(CheckConfig) ? check : checks(check), adapter: adapter,
      ).run
    end

    it "reports nothing for a config whose masks are all in order" do
      write("users", table("users", [
                             { "name" => "id" },
                             { "name" => "email", "replace_with" => "user{id}@example.com" },
                             { "name" => "api_token", "replace_with_random" => "hex:16" },
                             { "name" => "password_digest", "unset" => true },
                             { "name" => "phone", "allow_unmasked" => true },
                             { "name" => "nickname" },
                           ]))

      expect(report.slice("integrity", "guessable_credentials", "unmasked_sensitive")).to eq("integrity" => [], "guessable_credentials" => [], "unmasked_sensitive" => [])
      expect(described_class.clean?(report)).to be(true)
    end

    describe "which checks run" do
      before { write("users", table("users", [{ "name" => "id" }, { "name" => "email" }])) }

      it "runs only integrity by default" do
        result = report(check: CheckConfig.default)

        expect(result).to include("integrity" => [])
        expect(result).not_to have_key("guessable_credentials")
        expect(result).not_to have_key("unmasked_sensitive")
      end

      it "adds no key for a disabled check" do
        expect(report(check: { "integrity" => false })).not_to have_key("integrity")
      end
    end

    describe "integrity" do
      let(:only_integrity) { { "integrity" => true } }

      it "reports a masked primary key" do
        write("users", table("users", [{ "name" => "id", "raw_sql" => "NULL" }, { "name" => "email", "replace_with" => "x" }]))

        expect(report(check: only_integrity)["integrity"]).to eq(
          ["users.id [base]: the primary key is masked, which breaks the rows referencing it and mask-update, " \
           "which addresses rows by it; remove the mask"],
        )
      end

      it "reports a table that does not select its primary key, whether or not it declares masks" do
        write("users", table("users", [{ "name" => "id", "ignore" => true }, { "name" => "email", "replace_with" => "x" }]))
        write("logs", table("logs", [{ "name" => "id", "ignore" => true }, { "name" => "body" }]))

        expect(report(check: only_integrity)["integrity"]).to eq(%w[logs users].map do |name|
          "#{name}.id [base]: the primary key is not selected (is it ignored?), which breaks the rows referencing it " \
            "and mask-update, which addresses rows by it; select it"
        end)
      end

      it "leaves the allowances to the checks they belong to" do
        write("users", table("users", [
                               { "name" => "id" },
                               { "name" => "city", "replace_with" => "x", "allow_guessable_credential" => true },
                               { "name" => "nickname", "allow_unmasked" => true },
                             ]))

        expect(report(check: only_integrity)["integrity"]).to eq([])
      end
    end

    describe "guessable_credentials" do
      let(:only_credentials) { { "integrity" => false, "guessable_credentials" => true } }

      it "reports an allow_guessable_credential that guards nothing" do
        write("users", table("users", [
                               { "name" => "id" },
                               { "name" => "api_token", "unset" => true, "allow_guessable_credential" => true },
                               { "name" => "city", "replace_with" => "x", "allow_guessable_credential" => true },
                               { "name" => "secret", "allow_guessable_credential" => true },
                               { "name" => "password", "replace_with" => "x", "allow_guessable_credential" => true },
                             ]))

        expect(report(check: only_credentials)["guessable_credentials"]).to eq(%w[api_token city secret].map do |column|
          "users.#{column} [base]: sets allow_guessable_credential, but is not a credential-looking column " \
            "masked to a guessable value; remove it"
        end)
      end

      it "reports a credential-looking column masked to a guessable value, unless it allows that" do
        write("accounts", table("accounts", [
                                  { "name" => "id" },
                                  { "name" => "api_token", "replace_with" => "token-{id}" },
                                  { "name" => "password_digest", "map" => "->(_) { 'x' }" },
                                  { "name" => "session_secret", "replace_with" => "KNOWN", "allow_guessable_credential" => true },
                                  { "name" => "access_key", "unset" => true },
                                  { "name" => "reset_token", "replace_with_random" => "hex:32" },
                                  { "name" => "private_key", "raw_sql" => "NULL" },
                                  { "name" => "client_secret", "raw_sql" => "lower(hex(randomblob(16)))" },
                                  { "name" => "salt" },
                                ]))

        expect(report(check: only_credentials)["guessable_credentials"]).to eq(
          %w[api_token client_secret password_digest private_key].map { |column| "accounts.#{column} [base]: #{guessable_reason}" },
        )
      end

      it "adds the configured patterns to the built-in one, and judges allow_guessable_credential by them" do
        write("accounts", table("accounts", [
                                  { "name" => "id" },
                                  { "name" => "pin_code", "replace_with" => "0000" },
                                  { "name" => "shop_pin", "replace_with" => "0000", "allow_guessable_credential" => true },
                                ]))

        result = report(check: { "integrity" => false, "guessable_credentials" => { "patterns" => ["(^|_)pin(_|$)"] } })
        expect(result["guessable_credentials"].map { |entry| entry[/\A\S+/] }).to eq(%w[accounts.pin_code])
        expect(report(check: only_credentials)["guessable_credentials"].map { |entry| entry[/\A\S+/] }).to eq(%w[accounts.shop_pin])
      end

      it "judges by what the name says the value is, not by how it is stored, and leaves out timestamps" do
        write("accounts", table("accounts", [
                                  { "name" => "id" },
                                  { "name" => "encrypted_card_expiry", "replace_with" => "12" },
                                  { "name" => "encrypted_password", "replace_with" => "x" },
                                  { "name" => "encrypted_private_jwk", "replace_with" => "x" },
                                  { "name" => "signing_privatekey", "replace_with" => "x" },
                                  { "name" => "access_token_expires_at", "replace_with" => "2000-01-01" },
                                ]))

        expect(report(check: only_credentials)["guessable_credentials"].map { |entry| entry[/\A\S+/] })
          .to eq(%w[accounts.encrypted_password accounts.encrypted_private_jwk accounts.signing_privatekey])
      end

    end

    describe "unmasked_sensitive" do
      let(:only_unmasked) { { "integrity" => false, "unmasked_sensitive" => true } }

      it "reports an allow_unmasked that allows nothing, saying why" do
        write("users", table("users", [
                               { "name" => "id", "allow_unmasked" => true },
                               { "name" => "shop_id", "allow_unmasked" => true },
                               { "name" => "email", "replace_with" => "x", "allow_unmasked" => true },
                               { "name" => "nickname", "allow_unmasked" => true },
                               { "name" => "phone", "allow_unmasked" => true },
                             ], belongs_tos: [{ "foreign_key" => "shop_id", "table_name" => "shops" }]))
        write("shops", table("shops", [{ "name" => "id" }]))

        expect(report(check: only_unmasked)["unmasked_sensitive"]).to eq([
          "users.email [base]: sets allow_unmasked, but it is masked; remove it",
          "users.id [base]: sets allow_unmasked, but it is the primary key or a belongs_to foreign key, which are never masked; remove it",
          "users.nickname [base]: sets allow_unmasked, but its name matches no mask pattern; remove it",
          "users.shop_id [base]: sets allow_unmasked, but it is the primary key or a belongs_to foreign key, which are never masked; remove it",
        ])
      end

      it "counts the configured patterns when judging allow_unmasked" do
        write("users", table("users", [{ "name" => "id" }, { "name" => "name_kana", "allow_unmasked" => true }]))

        expect(report(check: { "integrity" => false, "unmasked_sensitive" => { "patterns" => ["(^|_)kana(_|$)"] } })["unmasked_sensitive"])
          .to eq([])
        expect(report(check: only_unmasked)["unmasked_sensitive"].join).to include("users.name_kana [base]: sets allow_unmasked")
      end

      it "reports an unmasked column whose name looks sensitive" do
        write("users", table("users", [
                               { "name" => "id" },
                               { "name" => "email" },
                               { "name" => "billing_address", "raw_sql" => "NULL" },
                               { "name" => "phone_number", "allow_unmasked" => true },
                               { "name" => "birthday", "ignore" => true },
                               { "name" => "nickname" },
                             ]))

        expect(report(check: only_unmasked)["unmasked_sensitive"]).to eq(
          ["users.email [base]: looks sensitive but is not masked; add a mask, or set allow_unmasked if the real value is needed"],
        )
      end

      it "counts what is stored encrypted, and leaves out timestamps" do
        write("users", table("users", [
                               { "name" => "id" },
                               { "name" => "encrypted_card_expiry" },
                               { "name" => "email_updated_at" },
                               { "name" => "phone_verified_at", "allow_unmasked" => true },
                             ]))

        expect(report(check: only_unmasked)["unmasked_sensitive"]).to eq([
          "users.encrypted_card_expiry [base]: looks sensitive but is not masked; add a mask, or set allow_unmasked if the real value is needed",
          "users.phone_verified_at [base]: sets allow_unmasked, but its name matches no mask pattern; remove it",
        ])
      end

      it "exempts the primary key and belongs_to foreign keys" do
        write("users", table("users", [{ "name" => "id" }, { "name" => "address_id" }], primary_key: "id",
                                                                                      belongs_tos: [{ "foreign_key" => "address_id", "table_name" => "addresses" }]))
        write("addresses", table("addresses", [{ "name" => "id" }, { "name" => "city" }]))
        write("emails", table("emails", [{ "name" => "email" }, { "name" => "body", "raw_sql" => "NULL" }], primary_key: "email"))

        expect(report(check: only_unmasked)["unmasked_sensitive"]).to eq([])
      end

      it "adds the configured patterns to the defaults" do
        write("users", table("users", [{ "name" => "id" }, { "name" => "email" }, { "name" => "name_kana" }]))

        result = report(check: { "integrity" => false, "unmasked_sensitive" => { "patterns" => ["(^|_)kana(_|$)"] } })
        expect(result["unmasked_sensitive"].map { |entry| entry[/\A\S+/] }).to eq(%w[users.email users.name_kana])
      end
    end

    describe "tables the checks skip" do
      it "skips ignored, rails-managed and composite-key tables, as mask-update refuses them" do
        write("ignored", table("ignored", [{ "name" => "id", "raw_sql" => "NULL" }, { "name" => "email" }], ignore: true))
        write("schema_migrations", { "name" => "schema_migrations", "type" => TableConfig::RAILS_MANAGED_SCHEMA_MIGRATIONS })
        write("pairs", table("pairs", [{ "name" => "email" }], primary_key: nil, ignore: true,
                                                               type: TableConfig::UNSUPPORTED_COMPOSITE_PRIMARY_KEY))

        expect(report.slice("integrity", "guessable_credentials", "unmasked_sensitive")).to eq("integrity" => [], "guessable_credentials" => [], "unmasked_sensitive" => [])
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
                                    { "name" => "refresh_token", "replace_with_random" => "hex:16" },
                                    { "name" => "password", "unset" => true },
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
        result = mongo_report({ "integrity" => true, "guessable_credentials" => true, "unmasked_sensitive" => true })

        expect(result["unmasked_sensitive"].map { |entry| entry[/\A\S+/] }).to eq(%w[users.email users.profile.addresses.city users.profile.addresses.zip_code])
        expect(result["guessable_credentials"]).to eq([
          "users.api_token [base]: #{guessable_reason}",
          "users.nickname [base]: sets allow_guessable_credential, but is not a credential-looking column masked to a guessable value; remove it",
          "users.profile.addresses.secret [base]: #{guessable_reason}",
        ])
        expect(result["unmasked_sensitive"]).to include(
          "users.profile.addresses.city [base]: sets allow_unmasked, but its name matches no mask pattern; remove it",
        )
        expect(result["integrity"]).to eq([])
      end

      it "accepts a guessable credential that allows it, and a sensitive field that allows being unmasked" do
        write("users", collection("users", [
                                    { "name" => "_id" },
                                    { "name" => "email", "allow_unmasked" => true },
                                    { "name" => "api_token", "replace_with" => "x", "allow_guessable_credential" => true },
                                  ]))
        write("addresses", collection("addresses", [{ "name" => "_id" }, { "name" => "zip_code", "replace_with" => "000" }],
                                      embedded_in: { "collection_name" => "users", "path" => "addresses" }))

        result = mongo_report({ "integrity" => true, "guessable_credentials" => true, "unmasked_sensitive" => true })
        expect(result.slice("integrity", "guessable_credentials", "unmasked_sensitive")).to eq("integrity" => [], "guessable_credentials" => [], "unmasked_sensitive" => [])
      end

      it "reports a masked _id" do
        write("users", collection("users", [{ "name" => "_id", "replace_with" => "x" }]))
        File.delete(File.join(schema_dir, "addresses.json"))

        expect(mongo_report({ "integrity" => true })["integrity"])
          .to eq(["users._id [base]: the primary key is masked, which breaks the rows referencing it and mask-update, " \
                  "which addresses rows by it; remove the mask"])
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
        expect(report(check: { "unmasked_sensitive" => true })["unmasked_sensitive"].map { |entry| entry[/\A[^:]+/] })
          .to eq(["users.email [base, dev, ci]", "users.phone [base, ci]"])
      end

      it "runs a check against the selected profiles only" do
        expect(report(check: { "unmasked_sensitive" => { "profiles" => %w[dev] } })["unmasked_sensitive"].map { |entry| entry[/\A[^:]+/] })
          .to eq(["users.email [dev]"])
      end

      it "lets an overlay un-mask a column with allow_unmasked, dropping the base mask" do
        write("users", table("users", [{ "name" => "id" }, { "name" => "email", "replace_with" => "x" }]))
        File.write(File.join(schema_dir, "users.dev.json"), JSON.generate(
                                                              "name" => "users", "columns" => [{ "name" => "email", "allow_unmasked" => true }],
                                                            ))

        result = report
        expect(result["unmasked_sensitive"]).to eq([])
        expect(result["integrity"]).to eq([])
      end
    end

    describe "databases" do
      it "labels each finding with its database directory" do
        write("accounts", table("accounts", [{ "name" => "id" }, { "name" => "api_token", "replace_with_random" => "hex:16" }]),
              dir: File.join(schema_dir, "primary"))
        write("accounts", table("accounts", [{ "name" => "id" }, { "name" => "api_token", "replace_with" => "x" }]),
              dir: File.join(schema_dir, "legacy"))
        adapters = { "primary" => "postgresql", "legacy" => "mysql" }

        result = report(check: { "guessable_credentials" => true }, adapter: ->(database) { adapters.fetch(database) })
        expect(result["guessable_credentials"].map { |entry| entry[/\A\S+/] }).to eq(%w[legacy/accounts.api_token])
      end

      it "fails loudly when the adapter is unknown" do
        write("users", table("users", [{ "name" => "id" }]))

        expect { report(adapter: nil) }.to raise_error(ArgumentError, /needs the database adapter to run the integrity, guessable_credentials, unmasked_sensitive check/)
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
        expect(described_class.failed_checks(result)).to eq(%w[unmasked_sensitive])
      end
    end
  end
end
