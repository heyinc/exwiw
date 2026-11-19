# frozen_string_literal: true

require "spec_helper"

module Exwiw
  RSpec.describe ConfigOverlay do
    let(:base) do
      {
        "name" => "users",
        "primary_key" => "id",
        "filter" => "users.active = 1",
        "belongs_tos" => [
          { "table_name" => "shops", "foreign_key" => "shop_id" },
          { "table_name" => "products", "foreign_key" => "item_id", "foreign_type" => "item_type", "type_value" => "Product" },
        ],
        "columns" => [
          { "name" => "id" },
          { "name" => "name", "raw_sql" => "('masked' || users.id)" },
          { "name" => "email", "replace_with" => "masked{id}@example.com", "comment" => "keep" },
          { "name" => "shop_id" },
        ],
        "batch_scope" => { "table" => "shops", "size" => 10 },
      }
    end

    describe ".validate_unique_keys!" do
      it "rejects two list entries with the same key" do
        config = base.merge("belongs_tos" => [base["belongs_tos"][0], base["belongs_tos"][0].merge("comment" => "x")])

        expect { described_class.validate_unique_keys!(TableConfig, config, owner: "users.json") }
          .to raise_error(ArgumentError, /users.json has more than one belongs_tos\[table_name=shops,foreign_key=shop_id\] entry/)
      end

      it "accepts unique keys" do
        expect { described_class.validate_unique_keys!(TableConfig, base, owner: "users.json") }.not_to raise_error
      end
    end
  end
end
