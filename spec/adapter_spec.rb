require 'spec_helper'

module Exwiw
  module Adapter
    RSpec.describe '.normalize_name' do
      it 'returns canonical names unchanged' do
        expect(Adapter.normalize_name('mysql')).to eq('mysql')
        expect(Adapter.normalize_name('sqlite')).to eq('sqlite')
        expect(Adapter.normalize_name('postgresql')).to eq('postgresql')
        expect(Adapter.normalize_name('mongodb')).to eq('mongodb')
      end

      it 'folds the older driver-flavored spellings onto the canonical name' do
        expect(Adapter.normalize_name('mysql2')).to eq('mysql')
        expect(Adapter.normalize_name('sqlite3')).to eq('sqlite')
      end

      it 'is case-insensitive so Rails connection.adapter_name is absorbed' do
        expect(Adapter.normalize_name('Mysql2')).to eq('mysql')
        expect(Adapter.normalize_name('SQLite')).to eq('sqlite')
        expect(Adapter.normalize_name('PostgreSQL')).to eq('postgresql')
      end

      it 'does not alias trilogy (exwiw connects via the mysql2 gem)' do
        expect(Adapter.normalize_name('trilogy')).to eq('trilogy')
      end

      it 'passes unknown names through (downcased) so callers can reject them' do
        expect(Adapter.normalize_name('oracle')).to eq('oracle')
      end

      it 'returns nil for nil' do
        expect(Adapter.normalize_name(nil)).to be_nil
      end
    end

    RSpec.describe '.build' do
      let(:logger) { Logger.new(IO::NULL) }

      it 'builds the canonical adapter for an alias spelling' do
        config = ConnectionConfig.new(adapter: 'mysql2', database_name: 'x')
        expect(Adapter.build(config, logger)).to be_a(Adapter::MysqlAdapter)
      end

      it 'raises a descriptive error for an unsupported adapter' do
        config = ConnectionConfig.new(adapter: 'oracle', database_name: 'x')
        expect { Adapter.build(config, logger) }.to raise_error(/Unsupported adapter.*oracle/)
      end
    end
  end
end
