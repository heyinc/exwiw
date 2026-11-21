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

    RSpec.describe ".normalize_active_record_name" do
      it "reads trilogy as mysql, case-insensitively" do
        expect(Adapter.normalize_active_record_name("trilogy")).to eq("mysql")
        expect(Adapter.normalize_active_record_name("Trilogy")).to eq("mysql")
      end

      it "normalizes the other names as .normalize_name does" do
        expect(Adapter.normalize_active_record_name("Mysql2")).to eq("mysql")
        expect(Adapter.normalize_active_record_name("postgresql")).to eq("postgresql")
        expect(Adapter.normalize_active_record_name(nil)).to be_nil
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

    RSpec.describe '#escape_value' do
      %w[sqlite mysql postgresql].each do |name|
        context "with the #{name} adapter" do
          let(:adapter) { Adapter.build(ConnectionConfig.new(adapter: name, database_name: 'x'), Logger.new(nil)) }

          it 'writes nil, strings and plain numbers or booleans as SQL literals' do
            expect(adapter.send(:escape_value, nil)).to eq('NULL')
            expect(adapter.send(:escape_value, "it's")).to eq(name == 'mysql' ? "'it''s'" : "'it''s'")
            expect(adapter.send(:escape_value, 12)).to eq('12')
            expect(adapter.send(:escape_value, -1.5)).to eq('-1.5')
            expect(adapter.send(:escape_value, 1.0e-05)).to eq('1.0e-05')
            expect(adapter.send(:escape_value, true)).to eq('true')
            expect(adapter.send(:escape_value, false)).to eq('false')
          end

          it 'refuses a value whose text is not a SQL literal instead of embedding it' do
            [Float::NAN, Float::INFINITY, Rational(1, 3), [1, 2], { 'a' => 1 }, :sym, Object.new, Time.utc(2026, 1, 1)].each do |value|
              expect { adapter.send(:escape_value, value) }
                .to raise_error(UnsupportedValueError, /cannot write .* as an SQL literal/)
            end
          end
        end
      end
    end
  end
end
