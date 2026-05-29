require 'spec_helper'

module Exwiw
  RSpec.describe TableConfig do
    describe '#merge' do
      let(:current_config) do
        TableConfig.from_symbol_keys(
          name: 'users',
          primary_key: 'id',
          belongs_tos: current_belongs_tos,
          columns: current_columns,
        )
      end
      let(:current_belongs_tos) do
        []
      end
      let(:current_columns) do
        [{ name: 'id' }]
      end
      let(:passed_config) do
        TableConfig.from_symbol_keys(
          name: 'users',
          primary_key: 'id',
          belongs_tos: passed_belongs_tos,
          columns: passed_columns,
        )
      end
      let(:passed_belongs_tos) do
        []
      end
      let(:passed_columns) do
        [{ name: 'id' }]
      end
      let(:merged_config) do
        current_config.merge(passed_config)
      end

      context 'when passed config is same as receiver' do
        it 'returns same config with receiver' do
          expect(merged_config.to_hash).to eq(current_config.to_hash)
        end
      end

      context 'when passed config has new belongs_to' do
        let(:current_belongs_tos) do
          []
        end
        let(:passed_belongs_tos) do
          [{ table_name: 'clients', foreign_key: 'company_id' }]
        end

        it 'returns merged belongs_to' do
          actual = merged_config.belongs_tos
          expect(actual.map(&:to_hash)).to eq([
            { 'table_name' => 'clients', 'foreign_key' => 'company_id' },
          ])
        end
      end

      context 'when passed config has less belongs_to' do
        let(:current_belongs_tos) do
          [{ table_name: 'clients', foreign_key: 'company_id' }]
        end
        let(:passed_belongs_tos) do
          []
        end

        it 'returns less belongs_to' do
          actual = merged_config.belongs_tos
          expect(actual).to eq([])
        end
      end

      context 'when passed config has different foreign_key' do
        let(:current_belongs_tos) do
          [{ table_name: 'clients', foreign_key: 'company_id' }]
        end
        let(:passed_belongs_tos) do
          [{ table_name: 'clients', foreign_key: 'merchant_id' }]
        end

        it 'prefer passed config data' do
          actual = merged_config.belongs_tos
          expect(actual.map(&:to_hash)).to eq([
            { 'table_name' => 'clients', 'foreign_key' => 'merchant_id' },
          ])
        end
      end

      context 'when passed config has new columns' do
        let(:current_columns) do
          [{ name: 'id' }]
        end
        let(:passed_columns) do
          [{ name: 'id' }, { name: 'name' }]
        end

        it 'returns merged columns' do
          actual = merged_config.columns
          expect(actual.map(&:to_hash)).to eq([
            { 'name' => 'id' },
            { 'name' => 'name' },
          ])
        end
      end

      context 'when passed config has same columns' do
        let(:current_columns) do
          [{ name: 'id' }, { name: 'name', replace_with: 'MaskedName{id}' }]
        end
        let(:passed_columns) do
          [{ name: 'id' }, { name: 'name' }]
        end

        it 'returns same columns with receiver' do
          actual = merged_config.columns
          expect(actual.map(&:to_hash)).to eq([
            { 'name' => 'id' },
            { 'name' => 'name', 'replace_with' => 'MaskedName{id}' },
          ])
        end
      end

      context 'when receiver has skip:true' do
        let(:current_config) do
          TableConfig.from_symbol_keys(
            name: 'users',
            primary_key: 'id',
            skip: true,
            belongs_tos: current_belongs_tos,
            columns: current_columns,
          )
        end

        it 'preserves skip from the receiver in the merged config' do
          expect(merged_config.skip).to eq(true)
        end
      end

      context 'when passed config has less columns' do
        let(:current_columns) do
          [{ name: 'id' }, { name: 'name', replace_with: 'MaskedName{id}' }, { name: 'email' }]
        end
        let(:passed_columns) do
          [{ name: 'id' }, { name: 'name' }]
        end

        it 'returns less columns' do
          actual = merged_config.columns
          expect(actual.map(&:to_hash)).to eq([
            { 'name' => 'id' },
            { 'name' => 'name', 'replace_with' => 'MaskedName{id}' },
          ])
        end
      end

      context 'when type and comment are involved' do
        let(:current_config) do
          TableConfig.from_symbol_keys(
            name: 'users',
            primary_key: 'id',
            comment: 'localized comment',
            belongs_tos: [],
            columns: [{ name: 'id' }],
          )
        end
        let(:passed_config) do
          TableConfig.from_symbol_keys(
            name: 'users',
            primary_key: 'id',
            type: 'some_type',
            comment: 'generator comment',
            belongs_tos: [],
            columns: [{ name: 'id' }],
          )
        end

        it 'takes type from passed config (generator-owned)' do
          expect(merged_config.type).to eq('some_type')
        end

        it 'preserves comment from receiver (user-owned)' do
          expect(merged_config.comment).to eq('localized comment')
        end
      end
    end

    describe 'rails_managed validation' do
      context 'when type is rails_managed_schema_migrations' do
        it 'rejects primary_key' do
          expect {
            TableConfig.from_symbol_keys(
              name: 'schema_migrations',
              primary_key: 'version',
              type: TableConfig::RAILS_MANAGED_SCHEMA_MIGRATIONS,
            )
          }.to raise_error(ArgumentError, /primary_key must not be defined/)
        end

        it 'rejects non-empty belongs_tos' do
          expect {
            TableConfig.from_symbol_keys(
              name: 'schema_migrations',
              type: TableConfig::RAILS_MANAGED_SCHEMA_MIGRATIONS,
              belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id' }],
            )
          }.to raise_error(ArgumentError, /belongs_tos must not be defined/)
        end

        it 'rejects non-empty columns' do
          expect {
            TableConfig.from_symbol_keys(
              name: 'schema_migrations',
              type: TableConfig::RAILS_MANAGED_SCHEMA_MIGRATIONS,
              columns: [{ name: 'version' }],
            )
          }.to raise_error(ArgumentError, /columns must not be defined/)
        end

        it 'loads successfully with only name/type/comment' do
          expect {
            TableConfig.from_symbol_keys(
              name: 'schema_migrations',
              type: TableConfig::RAILS_MANAGED_SCHEMA_MIGRATIONS,
              comment: 'managed by Rails',
            )
          }.not_to raise_error
        end
      end

      context 'when type is rails_managed_internal_metadata' do
        it 'rejects primary_key just like schema_migrations' do
          expect {
            TableConfig.from_symbol_keys(
              name: 'ar_internal_metadata',
              primary_key: 'key',
              type: TableConfig::RAILS_MANAGED_INTERNAL_METADATA,
            )
          }.to raise_error(ArgumentError, /primary_key must not be defined/)
        end
      end

      context 'when type is not rails-managed' do
        it 'requires primary_key' do
          expect {
            TableConfig.from_symbol_keys(
              name: 'users',
              belongs_tos: [],
              columns: [{ name: 'id' }],
            )
          }.to raise_error(ArgumentError, /requires primary_key/)
        end
      end
    end

    describe '#to_hash for rails_managed' do
      let(:config) do
        TableConfig.from_symbol_keys(
          name: 'schema_migrations',
          type: TableConfig::RAILS_MANAGED_SCHEMA_MIGRATIONS,
          comment: 'managed by Rails',
        )
      end

      it 'omits primary_key, belongs_tos, and columns' do
        hash = config.to_hash
        expect(hash).not_to have_key('primary_key')
        expect(hash).not_to have_key('belongs_tos')
        expect(hash).not_to have_key('columns')
      end

      it 'keeps name, type, and comment' do
        hash = config.to_hash
        expect(hash['name']).to eq('schema_migrations')
        expect(hash['type']).to eq(TableConfig::RAILS_MANAGED_SCHEMA_MIGRATIONS)
        expect(hash['comment']).to eq('managed by Rails')
      end

      it 'round-trips through JSON without the omitted keys' do
        json = JSON.pretty_generate(config.to_hash)
        reloaded = TableConfig.from(JSON.parse(json))
        expect(reloaded.rails_managed?).to eq(true)
        expect(reloaded.belongs_tos).to eq([])
        expect(reloaded.columns).to eq([])
      end
    end
  end
end
