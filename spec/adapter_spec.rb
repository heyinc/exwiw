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

    RSpec.describe Base, '#write_inserts (default seam)' do
      # A minimal Base subclass whose per-row serialization is trivial and whose
      # chunk size is controllable, so the test pins the default seam's framing
      # (chunk -> write_bulk_insert -> "\n"-joined, no leading/trailing separator)
      # without a database.
      let(:adapter_class) do
        Class.new(Base) do
          def initialize(chunk_default)
            @chunk_default = chunk_default
          end

          def default_bulk_insert_chunk_size = @chunk_default

          # One "INSERT(...)" statement per chunk listing the chunk's rows, so the
          # number of statements and their boundaries are visible in the bytes.
          def to_bulk_insert(rows, _table) = "INSERT(#{rows.join(',')})"
        end
      end

      # Stand-in table config: only #bulk_insert_chunk_size is read by the seam.
      let(:table) { Struct.new(:bulk_insert_chunk_size).new(nil) }
      let(:rows) { %w[a b c d e] }

      def write(adapter, table, rows)
        io = StringIO.new
        count = adapter.write_inserts(io, rows, table)
        [io.string, count]
      end

      it 'emits one statement for the whole table when no chunk size is set' do
        output, count = write(adapter_class.new(nil), table, rows)
        expect(output).to eq("INSERT(a,b,c,d,e)")
        expect(count).to eq(1)
      end

      it 'chunks by the adapter default, joining statements with one "\n" and no leading/trailing separator' do
        output, count = write(adapter_class.new(2), table, rows)
        expect(output).to eq("INSERT(a,b)\nINSERT(c,d)\nINSERT(e)")
        expect(count).to eq(3)
      end

      it 'lets the table config bulk_insert_chunk_size override the adapter default' do
        table.bulk_insert_chunk_size = 3
        output, count = write(adapter_class.new(2), table, rows)
        expect(output).to eq("INSERT(a,b,c)\nINSERT(d,e)")
        expect(count).to eq(2)
      end

      it 'produces bytes identical to a "\n"-join of the per-chunk write_bulk_insert output (the Runner body contract)' do
        adapter = adapter_class.new(2)
        actual, = write(adapter, table, rows)

        expected = rows.each_slice(2).map { |chunk| adapter.to_bulk_insert(chunk, table) }.join("\n")
        expect(actual).to eq(expected)
      end
    end
  end
end
