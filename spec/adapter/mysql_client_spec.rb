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
        it 'prefers mysql2 when it is available' do
          expect(MysqlClient.detect_driver).to eq(:mysql2)
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
      end
    end
  end
end
