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
    end
  end
end
