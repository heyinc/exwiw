require 'spec_helper'

module Exwiw
  RSpec.describe MongodbCollectionConfig do
    describe '.from' do
      context 'without embedded_in' do
        let(:json) do
          {
            "name" => "users",
            "primary_key" => "_id",
            "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "shop_id" }],
            "fields" => [
              { "name" => "_id" },
              { "name" => "name", "replace_with" => "masked{_id}" },
              { "name" => "shop_id" },
            ],
          }
        end

        it 'loads a top-level collection config' do
          config = described_class.from(json)
          expect(config.name).to eq("users")
          expect(config.primary_key).to eq("_id")
          expect(config.belongs_tos.map(&:to_hash)).to eq([
            { "table_name" => "shops", "foreign_key" => "shop_id" },
          ])
          expect(config.fields.map(&:to_hash)).to eq([
            { "name" => "_id" },
            { "name" => "name", "replace_with" => "masked{_id}" },
            { "name" => "shop_id" },
          ])
          expect(config.embedded_in).to be_nil
          expect(config.embedded?).to eq(false)
        end
      end

      context 'with embedded_in' do
        let(:json) do
          {
            "name" => "posts",
            "primary_key" => "_id",
            "embedded_in" => { "collection_name" => "users", "path" => "posts" },
            "belongs_tos" => [],
            "fields" => [
              { "name" => "_id" },
              { "name" => "title", "replace_with" => "masked-{_id}" },
            ],
          }
        end

        it 'loads an embedded config and reports embedded? true' do
          config = described_class.from(json)
          expect(config.embedded?).to eq(true)
          expect(config.embedded_in.collection_name).to eq("users")
          expect(config.embedded_in.path).to eq("posts")
        end

        it 'serializes back to a hash with embedded_in' do
          config = described_class.from(json)
          dumped = config.to_hash
          expect(dumped["embedded_in"]).to eq({ "collection_name" => "users", "path" => "posts" })
        end
      end

      context 'when embedded_in is set together with non-empty belongs_tos' do
        let(:json) do
          {
            "name" => "posts",
            "primary_key" => "_id",
            "embedded_in" => { "collection_name" => "users", "path" => "posts" },
            "belongs_tos" => [{ "table_name" => "users", "foreign_key" => "user_id" }],
            "fields" => [{ "name" => "_id" }],
          }
        end

        it 'raises ArgumentError' do
          expect { described_class.from(json) }.to raise_error(ArgumentError, /belongs_tos must be empty/)
        end
      end

      context 'with ignore:true' do
        let(:json) do
          {
            "name" => "logs",
            "primary_key" => "_id",
            "ignore" => true,
            "belongs_tos" => [],
            "fields" => [{ "name" => "_id" }],
          }
        end

        it 'loads ignore and round-trips through to_hash' do
          config = described_class.from(json)
          expect(config.ignore).to eq(true)
          expect(config.to_hash["ignore"]).to eq(true)
        end
      end

      context 'when fields contain raw_sql key' do
        let(:json) do
          {
            "name" => "users",
            "primary_key" => "_id",
            "belongs_tos" => [],
            "fields" => [
              { "name" => "raw", "raw_sql" => "CONCAT('a','b')" },
            ],
          }
        end

        it 'silently ignores raw_sql since MongodbField does not declare it' do
          config = described_class.from(json)
          expect(config.fields.first.to_hash).to eq({ "name" => "raw" })
        end
      end
    end

    describe '#merge' do
      let(:current) do
        described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id', comment: 'bt note', ignore: true }],
          fields: [
            { name: '_id' },
            { name: 'token', comment: 'secret', ignore: true, replace_with: 'X' },
          ],
        )
      end
      let(:passed) do
        described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id' }],
          fields: [{ name: '_id' }, { name: 'token' }, { name: 'extra' }],
        )
      end

      it 'preserves user-owned comment/ignore on belongs_tos' do
        merged = current.merge(passed)
        expect(merged.belongs_tos.map(&:to_hash)).to eq([
          { 'table_name' => 'shops', 'foreign_key' => 'shop_id', 'comment' => 'bt note', 'ignore' => true },
        ])
      end

      it 'preserves user-owned comment/ignore/replace_with on fields while tracking added fields' do
        merged = current.merge(passed)
        token = merged.fields.find { |f| f.name == 'token' }
        expect(token.to_hash).to eq({ 'name' => 'token', 'replace_with' => 'X', 'comment' => 'secret', 'ignore' => true })
        expect(merged.fields.map(&:name)).to eq(['_id', 'token', 'extra'])
      end
    end

    describe '#reject_ignored_members!' do
      let(:config) do
        described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id', ignore: true }],
          fields: [{ name: '_id' }, { name: 'token', ignore: true }],
        )
      end

      it 'drops belongs_tos and fields flagged ignore:true' do
        config.reject_ignored_members!
        expect(config.belongs_tos).to eq([])
        expect(config.fields.map(&:name)).to eq(['_id'])
      end

      it 'returns self so it can be chained after load' do
        expect(config.reject_ignored_members!).to be(config)
      end
    end

    describe '.from_symbol_keys' do
      it 'accepts symbol keys' do
        config = described_class.from_symbol_keys(
          name: "users",
          primary_key: "_id",
          belongs_tos: [],
          fields: [{ name: "_id" }],
        )
        expect(config.name).to eq("users")
        expect(config.fields.first.name).to eq("_id")
      end
    end
  end
end
