# frozen_string_literal: true

require "spec_helper"

module Exwiw
  RSpec.describe MaskRules do
    describe "DEFAULT_MASK_PATTERNS" do
      %w[
        email e_mail contact_email phone phone_number telephone mobile mobile_number tel fax_no
        address billing_address zip zip_code postal_code birthday date_of_birth first_name lastname full_name
        ssn cvv card_number cardnumber otp otp_secret password_digest api_token
      ].each do |name|
        it "matches #{name}" do
          expect(described_class.sensitive_name?(name)).to be(true)
        end
      end

      %w[id name nickname title hotel gzip_size mobile_order_count shop_id created_at telemetry description].each do |name|
        it "does not match #{name}" do
          expect(described_class.sensitive_name?(name)).to be(false)
        end
      end
    end

    describe "described tables" do
      it "describes a SQL table's masks, safety and exemptions" do
        table = TableConfig.from_symbol_keys(
          name: "users", primary_key: "id",
          belongs_tos: [{ foreign_key: "shop_id", table_name: "shops" }],
          columns: [
            { name: "id" }, { name: "shop_id" },
            { name: "api_token", replace_with_random: "hex:16" },
            { name: "password", unset: true },
            { name: "salt", raw_sql: "NULL" },
            { name: "email", replace_with: "x", allow_unmasked: true },
          ],
        )

        described = table.describe_masks({ "users" => table })
        expect(described.columns.map { |c| [c.path, c.masked, c.safe, c.exempt, c.allow_unmasked] }).to eq([
          ["id", false, false, true, false],
          ["shop_id", false, false, true, false],
          ["api_token", true, true, false, false],
          ["password", true, true, false, false],
          ["salt", true, false, false, false],
          ["email", true, false, false, true],
        ])
      end

      it "describes a MongoDB collection with its embedded fields under their paths" do
        users = MongodbCollectionConfig.from_symbol_keys(
          name: "users", primary_key: "_id", belongs_tos: [],
          fields: [
            { name: "_id" }, { name: "token", replace_with: "x" }, { name: "secret", replace_with_random: "hex:16" },
            { name: "password", unset: true },
          ],
        )
        cards = MongodbCollectionConfig.from_symbol_keys(
          name: "cards", primary_key: "_id", belongs_tos: [],
          fields: [{ name: "_id" }, { name: "card_number" }],
          embedded_in: { collection_name: "users", path: "wallet.cards" },
        )
        ignored = MongodbCollectionConfig.from_symbol_keys(
          name: "notes", primary_key: "_id", belongs_tos: [], fields: [{ name: "email" }], ignore: true,
          embedded_in: { collection_name: "users", path: "notes" },
        )

        described = users.describe_masks({ "users" => users, "cards" => cards, "notes" => ignored })
        expect(described.columns.map { |c| [c.path, c.name, c.masked, c.safe, c.exempt] }).to eq([
          ["_id", "_id", false, false, true],
          ["token", "token", true, false, false],
          ["secret", "secret", true, true, false],
          ["password", "password", true, true, false],
          ["wallet.cards._id", "_id", false, false, true],
          ["wallet.cards.card_number", "card_number", false, false, false],
        ])
        expect(described_class.unmasked_sensitive(described)).to eq(["wallet.cards.card_number"])
      end
    end
  end
end
