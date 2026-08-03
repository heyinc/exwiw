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

      DRIVERS = [:mysql2, :trilogy].freeze

      # Pick the available driver, preferring mysql2 (exwiw's historical default).
      # require returns false when already loaded, so this is safe to call repeatedly.
      #
      # Set EXWIW_MYSQL_DRIVER=trilogy to force the pure-Ruby trilogy driver. This
      # is useful when the mysql2 gem is linked against a libmysqlclient that can
      # no longer load the server's auth plugin (e.g. MySQL 9.x client dropped the
      # `mysql_native_password` plugin .so, raising "Authentication plugin
      # 'mysql_native_password' cannot be loaded" on connect).
      def self.detect_driver
        forced = ENV['EXWIW_MYSQL_DRIVER']
        if forced && !forced.empty?
          sym = forced.to_sym
          unless DRIVERS.include?(sym)
            raise ArgumentError,
                  "EXWIW_MYSQL_DRIVER must be one of #{DRIVERS.join(', ')}, got #{forced.inspect}."
          end
          return sym
        end

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
        when String then normalize_encoding(value)
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

      # Re-tag a value string as UTF-8 when it comes back as ASCII-8BIT (BINARY).
      # Both drivers tag values from binary-collation / VARBINARY / BLOB columns
      # as ASCII-8BIT even when the bytes are really UTF-8 text. When exwiw runs
      # inside a host process whose Encoding.default_internal is UTF-8 (e.g. a
      # Rails app, or RUBYOPT=-EUTF-8), IO#write enables conversion, so writing
      # such a binary string carrying multi-byte bytes (e.g. Japanese "\xE4...")
      # to the INSERT file raises "\xE4 from ASCII-8BIT to UTF-8"
      # (Encoding::UndefinedConversionError). Re-tagging makes that write a
      # UTF-8 -> UTF-8 no-op; only the tag changes, the bytes pass through.
      def self.normalize_encoding(str)
        return str unless str.encoding == Encoding::ASCII_8BIT

        str.dup.force_encoding(Encoding::UTF_8)
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
          # mysql2 returns nil for a statement with no result set (SET, DDL, ...).
          return Result.new([], []) if res.nil?

          rows = res.to_a.map { |row| row.map { |value| self.class.stringify_value(value) } }
          Result.new(res.fields, rows)
        when :trilogy
          res = raw.query(sql)
          rows = res.rows.map { |row| row.map { |value| self.class.stringify_value(value) } }
          Result.new(res.fields, rows)
        else
          raise "Unsupported MySQL driver: #{@driver.inspect}"
        end
      end

      # Stream a query's rows one at a time, yielding each as an
      # Array<String|nil> (the same row shape as #query) instead of buffering
      # the whole result set. This keeps a large dump's dominant memory cost — a
      # Ruby array as big as the table — from materializing.
      #
      # mysql2 streams server-side (`stream: true` + `cache_rows: false`).
      # Its contract: a streamed result MUST be fully consumed before the next
      # query on this connection, or the driver raises "Commands out of sync".
      # The Runner consumes every row (it writes them all), but if the consumer
      # block raises mid-stream we drain the remaining rows so the same
      # connection is still usable for the next table's query.
      #
      # trilogy has no streaming cursor (no QUERY_FLAGS_STREAMING), so it buffers
      # the result and yields from it — parity, but without the memory win (the
      # same situation as the sqlite adapter). trilogy is a test-only driver;
      # production connects via mysql2.
      #
      # @param sql [String]
      # @yieldparam row [Array<String|nil>]
      def stream_rows(sql)
        return enum_for(:stream_rows, sql) unless block_given?

        case @driver
        when :mysql2
          res = raw.query(sql, cast: false, as: :array, stream: true, cache_rows: false)
          begin
            res.each { |row| yield row.map { |value| self.class.stringify_value(value) } }
          rescue StandardError
            begin
              res.each { |_row| } # drain the remainder so the connection stays usable
            rescue StandardError
              nil
            end
            raise
          end
        when :trilogy
          raw.query(sql).rows.each { |row| yield row.map { |value| self.class.stringify_value(value) } }
        else
          raise "Unsupported MySQL driver: #{@driver.inspect}"
        end
        self
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
