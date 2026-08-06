# frozen_string_literal: true

require "spec_helper"
require "bigdecimal"

module Exwiw
  RSpec.describe DefaultMask do
    def mask_for(type, name: "col", limit: nil, primary_key: "id", array: false, unique: false,
                 column_default: nil)
      described_class.for(
        name: name, type: type, limit: limit, primary_key: primary_key, array: array, unique: unique,
        column_default: column_default
      )
    end

    describe "per type" do
      {
        integer: 0,
        decimal: 0,
        float: 0,
        boolean: false,
        date: "2000-01-01",
        datetime: "2000-01-01 00:00:00",
        timestamp: "2000-01-01 00:00:00",
        time: "2000-01-01 00:00:00",
        json: "{}",
        jsonb: "{}",
        string: "masked-{id}",
        text: "masked-{id}",
      }.each do |type, expected|
        it "masks #{type} with #{expected.inspect}" do
          expect(mask_for(type)).to eq(expected)
        end
      end

      # A default the column cannot hold would fail the restore, which is worse
      # than exporting it while the flag blocks the merge.
      %i[uuid binary inet enum interval].each do |type|
        it "leaves #{type} unmasked, since no constant safely fits it" do
          expect(mask_for(type)).to be_nil
        end
      end
    end

    it "appends an example.com domain for a column that holds mail" do
      expect(mask_for(:string, name: "contact_email")).to eq("masked-{id}@example.com")
    end

    it "uses the table's own primary key as the template reference" do
      expect(mask_for(:string, primary_key: "uuid")).to eq("masked-{uuid}")
    end

    it "leaves text unmasked when there is no single primary key to key it on" do
      expect(mask_for(:string, primary_key: nil)).to be_nil
    end

    describe "length limits" do
      it "leaves a column too short for the masked value unmasked" do
        expect(mask_for(:string, limit: 8)).to be_nil
        expect(mask_for(:string, name: "email", limit: 20)).to be_nil
      end

      it "masks when the column can hold the value" do
        expect(mask_for(:string, limit: 255)).to eq("masked-{id}")
        expect(mask_for(:string, name: "email", limit: 255)).to eq("masked-{id}@example.com")
      end
    end

    describe "array columns" do
      # An array column reports its member type (`integer[]` is `:integer`), so
      # the scalar default would be rejected by the column on restore.
      it "leaves an array column unmasked whatever its member type" do
        expect(mask_for(:integer, array: true)).to be_nil
        expect(mask_for(:string, array: true)).to be_nil
      end
    end

    describe "a column with its own default" do
      # Masking a `default: true` flag with `false` would turn the feature off
      # for every row in the dump, so the column's own default wins.
      it "masks with the default instead of the per-type constant" do
        expect(mask_for(:boolean, column_default: true)).to eq(true)
        expect(mask_for(:boolean, column_default: false)).to eq(false)
        expect(mask_for(:integer, column_default: 5)).to eq(5)
        expect(mask_for(:float, column_default: 1.5)).to eq(1.5)
      end

      it "converts a default that replace_with cannot hold as-is" do
        expect(mask_for(:decimal, column_default: BigDecimal("9.99"))).to eq(9.99)
        expect(mask_for(:datetime, column_default: Time.utc(2020, 1, 2, 3, 4, 5)))
          .to eq("2020-01-02 03:04:05")
        expect(mask_for(:date, column_default: Date.new(2020, 1, 2))).to eq("2020-01-02")
        expect(mask_for(:jsonb, column_default: { "a" => 1 })).to eq('{"a":1}')
      end

      # A default computed by the database (`now()`) is not a constant, and
      # ActiveRecord reports it as nil, so it arrives here as "no default".
      it "falls back to the constant when the column has no default" do
        expect(mask_for(:boolean, column_default: nil)).to eq(false)
        expect(mask_for(:integer, column_default: nil)).to eq(0)
      end

      it "keeps the per-type constant for text, whose mask has to vary per row" do
        expect(mask_for(:string, column_default: "pending")).to eq("masked-{id}")
      end

      it "still refuses a constant default on a unique-indexed column" do
        expect(mask_for(:integer, column_default: 5, unique: true)).to be_nil
      end
    end

    describe "columns under a unique index" do
      it "leaves a constant-masked column unmasked, since every row would collide" do
        expect(mask_for(:integer, unique: true)).to be_nil
        expect(mask_for(:datetime, unique: true)).to be_nil
        expect(mask_for(:json, unique: true)).to be_nil
      end

      it "keeps a text mask, which varies per row through the primary key" do
        expect(mask_for(:string, unique: true)).to eq("masked-{id}")
        expect(mask_for(:string, name: "email", unique: true)).to eq("masked-{id}@example.com")
      end
    end
  end
end
