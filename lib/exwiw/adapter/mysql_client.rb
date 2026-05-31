# frozen_string_literal: true

require 'date'

module Exwiw
  module Adapter
    # Thin wrapper over the MySQL driver so MysqlAdapter does not care whether the
    # host app ships the `mysql2` gem or the `trilogy` gem. exwiw only runs simple
    # SELECT / EXPLAIN queries, so both drivers are normalized to the same shape:
    # rows as arrays of String|nil plus the column names.
    #
    # Values are normalized to strings to match mysql2's `cast: false` mode, where
    # every column comes back as a raw string and is quoted uniformly downstream
    # (see MysqlAdapter#escape_value). mysql2 already returns strings in that mode;
    # trilogy always casts to Ruby types (Integer / BigDecimal / Time / Date / ...),
    # so its values are stringified back into the same literal form here.
    class MysqlClient
      # Immutable value object: a query's column names and its rows.
      Result = Data.define(:fields, :rows)

      # Pick the available driver, preferring mysql2 (exwiw's historical default).
      # require returns false when already loaded, so this is safe to call repeatedly.
      def self.detect_driver
        require 'mysql2'
        :mysql2
      rescue LoadError
        begin
          require 'trilogy'
          :trilogy
        rescue LoadError
          raise LoadError,
                "exwiw needs the 'mysql2' or 'trilogy' gem to connect to MySQL. " \
                "Add `gem \"mysql2\"` (or `gem \"trilogy\"`) to your Gemfile."
        end
      end

      # Render a driver-returned value as the raw string mysql2's `cast: false`
      # would have produced, so trilogy's typed values quote identically.
      def self.stringify_value(value)
        case value
        when nil then nil
        when String then value
        when Time
          # Emit fractional seconds only when present. A Time can't tell us the
          # column's declared precision, so a zero fraction on a DATETIME(6)
          # column comes out as "...:00" here whereas mysql2's `cast: false`
          # echoes the raw "...:00.000000"; both re-insert to the same instant.
          value.nsec.zero? ? value.strftime('%Y-%m-%d %H:%M:%S') : value.strftime('%Y-%m-%d %H:%M:%S.%6N')
        when Date then value.strftime('%Y-%m-%d')
        when true then '1'
        when false then '0'
        else
          if defined?(BigDecimal) && value.is_a?(BigDecimal)
            value.to_s('F')
          else
            value.to_s
          end
        end
      end

      attr_reader :driver

      # `driver:` is mainly a test seam to force a specific driver; in normal use
      # it is auto-detected.
      def initialize(connection_config, driver: nil)
        @connection_config = connection_config
        @driver = (driver || self.class.detect_driver).to_sym
        ensure_driver_loaded!
      end

      # @param sql [String]
      # @return [Result] fields (Array<String>) and rows (Array<Array<String|nil>>)
      def query(sql)
        case @driver
        when :mysql2
          res = raw.query(sql, cast: false, as: :array)
          Result.new(res.fields, res.to_a)
        when :trilogy
          res = raw.query(sql)
          rows = res.rows.map { |row| row.map { |value| self.class.stringify_value(value) } }
          Result.new(res.fields, rows)
        else
          raise "Unsupported MySQL driver: #{@driver.inspect}"
        end
      end

      private def ensure_driver_loaded!
        case @driver
        when :mysql2 then require 'mysql2'
        when :trilogy then require 'trilogy'
        else raise "Unsupported MySQL driver: #{@driver.inspect}"
        end
      end

      private def raw
        @raw ||= build_raw
      end

      private def build_raw
        options = {
          host: @connection_config.host,
          port: @connection_config.port&.to_i,
          username: @connection_config.user,
          password: @connection_config.password,
          database: @connection_config.database_name,
        }.compact

        case @driver
        when :mysql2 then Mysql2::Client.new(options)
        when :trilogy then Trilogy.new(options)
        end
      end
    end
  end
end
