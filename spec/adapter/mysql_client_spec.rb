require 'spec_helper'
require 'bigdecimal'
require 'date'

module Exwiw
  module Adapter
    RSpec.describe MysqlClient do
      describe '.stringify_value' do
        it 'keeps nil and strings as-is' do
          expect(MysqlClient.stringify_value(nil)).to be_nil
          expect(MysqlClient.stringify_value('hello')).to eq('hello')
        end

        it 're-tags ASCII-8BIT strings (binary-collation columns) as UTF-8 without changing bytes' do
          utf8_bytes = 'あ'.encode('UTF-8')
          binary = utf8_bytes.dup.force_encoding(Encoding::ASCII_8BIT)

          result = MysqlClient.stringify_value(binary)

          expect(result.encoding).to eq(Encoding::UTF_8)
          expect(result.bytes).to eq(utf8_bytes.bytes)
          # The generated INSERT is written to a UTF-8 file, so this must not raise.
          expect { +'' << result }.not_to raise_error
        end

        it 'leaves already-UTF-8 strings untouched' do
          str = 'すでにUTF-8'
          expect(MysqlClient.stringify_value(str).encoding).to eq(Encoding::UTF_8)
        end

        it 'renders numbers as their literal text' do
          expect(MysqlClient.stringify_value(42)).to eq('42')
          expect(MysqlClient.stringify_value(BigDecimal('0.123e1'))).to eq('1.23')
        end

        it 'renders Time / Date in MySQL literal form (matching mysql2 cast: false)' do
          expect(MysqlClient.stringify_value(Time.new(2025, 1, 2, 3, 4, 5))).to eq('2025-01-02 03:04:05')
          expect(MysqlClient.stringify_value(Date.new(2025, 1, 2))).to eq('2025-01-02')
        end

        it 'renders booleans the way MySQL stores them' do
          expect(MysqlClient.stringify_value(true)).to eq('1')
          expect(MysqlClient.stringify_value(false)).to eq('0')
        end
      end

      describe '.detect_driver' do
        around do |example|
          original = ENV['EXWIW_MYSQL_DRIVER']
          example.run
          if original.nil?
            ENV.delete('EXWIW_MYSQL_DRIVER')
          else
            ENV['EXWIW_MYSQL_DRIVER'] = original
          end
        end

        it 'prefers mysql2 when it is available and no override is set' do
          ENV.delete('EXWIW_MYSQL_DRIVER')
          expect(MysqlClient.detect_driver).to eq(:mysql2)
        end

        it 'honors EXWIW_MYSQL_DRIVER=trilogy' do
          ENV['EXWIW_MYSQL_DRIVER'] = 'trilogy'
          expect(MysqlClient.detect_driver).to eq(:trilogy)
        end

        it 'honors EXWIW_MYSQL_DRIVER=mysql2' do
          ENV['EXWIW_MYSQL_DRIVER'] = 'mysql2'
          expect(MysqlClient.detect_driver).to eq(:mysql2)
        end

        it 'ignores an empty EXWIW_MYSQL_DRIVER and falls back to detection' do
          ENV['EXWIW_MYSQL_DRIVER'] = ''
          expect(MysqlClient.detect_driver).to eq(:mysql2)
        end

        it 'raises on an unknown EXWIW_MYSQL_DRIVER' do
          ENV['EXWIW_MYSQL_DRIVER'] = 'bogus'
          expect { MysqlClient.detect_driver }.to raise_error(ArgumentError, /EXWIW_MYSQL_DRIVER/)
        end
      end

      describe 'driver parity (mysql2 vs trilogy)' do
        let(:connection_config) do
          ConnectionConfig.new(
            adapter: 'mysql',
            host: '127.0.0.1',
            port: 3306,
            user: 'root',
            password: 'rootpassword',
            database_name: 'exwiw_test',
          )
        end

        # The seeded data exercises ints, strings, and datetimes, so the two
        # drivers' normalized rows must come out equivalent. The only allowed
        # divergence is an all-zero fractional part on a DATETIME(N) column
        # (mysql2 echoes the raw ".000000", trilogy's Time has no fraction to
        # render) — normalized away below since both re-insert identically.
        def strip_zero_fraction(rows)
          rows.map { |row| row.map { |v| v.is_a?(String) ? v.sub(/\.0+\z/, '') : v } }
        end

        it 'returns equivalent fields and rows for a SELECT regardless of driver' do
          sql = 'SELECT * FROM shops ORDER BY id'

          mysql2_result = MysqlClient.new(connection_config, driver: :mysql2).query(sql)
          trilogy_result = MysqlClient.new(connection_config, driver: :trilogy).query(sql)

          expect(trilogy_result.fields).to eq(mysql2_result.fields)
          expect(strip_zero_fraction(trilogy_result.rows)).to eq(strip_zero_fraction(mysql2_result.rows))
          expect(mysql2_result.rows).not_to be_empty
        end

        # #stream_rows must hand back the same rows #query buffers (the dump's
        # generated INSERT depends on this), for both drivers and after the
        # connection is reused for a follow-up query.
        %i[mysql2 trilogy].each do |driver|
          it "streams the same rows #query returns and leaves the connection usable (#{driver})" do
            client = MysqlClient.new(connection_config, driver: driver)
            sql = 'SELECT * FROM shops ORDER BY id'

            buffered = client.query(sql).rows
            streamed = client.stream_rows(sql).to_a

            expect(streamed).to eq(buffered)
            expect(streamed).not_to be_empty
            # The stream must be fully drained so the next query on this same
            # connection does not raise "Commands out of sync" (mysql2).
            expect(client.query('SELECT COUNT(*) FROM shops').rows.dig(0, 0).to_i).to eq(buffered.size)
          end
        end

        it 'drains the remainder when the consumer aborts mid-stream, keeping the connection usable (mysql2)' do
          client = MysqlClient.new(connection_config, driver: :mysql2)

          expect do
            client.stream_rows('SELECT * FROM shops ORDER BY id') { raise 'boom' }
          end.to raise_error('boom')

          # Connection recovered (remaining rows drained), so a follow-up succeeds.
          expect(client.query('SELECT COUNT(*) FROM shops').rows.dig(0, 0).to_i).to be > 0
        end

        # Scope id-set materialization issues SET / CREATE TEMPORARY TABLE /
        # ALTER TABLE through #query, and mysql2 returns nil for each of them.
        %i[mysql2 trilogy].each do |driver|
          it "returns an empty result for statements with no result set, keeping the connection usable (#{driver})" do
            client = MysqlClient.new(connection_config, driver: driver)
            sql_mode = client.query('SELECT @@SESSION.sql_mode').rows.dig(0, 0)

            statements = [
              "SET SESSION sql_mode = '#{sql_mode}'",
              'CREATE TEMPORARY TABLE exwiw_no_result_set_probe (id INT)',
              'ALTER TABLE exwiw_no_result_set_probe ADD INDEX `index_id` (id)',
            ]

            statements.each do |statement|
              result = client.query(statement)
              expect([result.fields, result.rows]).to eq([[], []]), "expected #{statement} to yield an empty result"
            end

            expect(client.query('SELECT COUNT(*) FROM exwiw_no_result_set_probe').rows).to eq([['0']])
          end
        end
      end
    end
  end
end
