# frozen_string_literal: true

module Exwiw
  module Adapter
    # Mask-UPDATE output shared by the SQL adapters, the counterpart of SqlBulkInsert: it formats the rows
    # MaskUpdateRunner reads with #build_query and #execute as UPDATE statements.
    module SqlMaskUpdate
      # A `random_bytes` of fewer bytes is guessable; more than the maximum is just wasteful.
      RANDOM_BYTES_RANGE = (16..1024)

      # Checks that `table` can be masked as declared, before any row is read.
      #
      # @param table [Exwiw::TableConfig] table to mask
      # @param _table_by_name [Hash{String => Exwiw::TableConfig}] every declared table by name
      # @return [Exwiw::MaskUpdateRunner::Checked]
      # @raise [Exwiw::MaskUpdateRunner::Error] when the table declares no mask, masks or does not select its primary key, or for an unaccepted credential-looking column
      def check_mask_update(table, _table_by_name)
        masked = masked_columns(table)
        if masked.empty?
          raise MaskUpdateRunner::Error,
                "table '#{table.name}' declares no mask (replace_with / raw_sql / map / replace_with_fake_data) on any column"
        end
        if masked.any? { |c| c.name == table.primary_key }
          raise MaskUpdateRunner::Error,
                "table '#{table.name}' masks its primary key '#{table.primary_key}', which selects the rows to update"
        end
        unless table.columns.any? { |c| c.name == table.primary_key }
          raise MaskUpdateRunner::Error,
                "table '#{table.name}' does not select its primary key '#{table.primary_key}' (is it ignored?), so its rows cannot be addressed"
        end

        masks = masked.map { |c| [c.name, safe_for_credential?(c)] }
        allowed = MaskUpdateRunner.check_credential_columns!(table.name, masks, table.columns.select(&:allow_guessable_mask).map(&:name))

        MaskUpdateRunner::Checked.new(columns: masked.map(&:name), allowed_guessable_columns: allowed)
      end

      # Builds one UPDATE per row of `results`, setting every masked column to the value `results` holds for it.
      # Rows are matched by what the database returns (a case-insensitive collation can return "abc" for "ABC").
      #
      # @param results [Enumerable<Array>] rows of the query #build_query builds, already through the RowTransformer
      # @param table [Exwiw::TableConfig] table to mask
      # @param primary_key_values [Array<Integer, String>] the given primary keys (at most MaskUpdateRunner::CHUNK_SIZE)
      # @param extra_assignments [Hash{String => Object}] columns set to a fixed value on every row found, unless masked
      # @return [Array(Array<String>, Integer, Array)] the UPDATE statements, rows found, given keys with no row
      # @raise [Exwiw::MaskUpdateRunner::Error] for a row the database matched only after converting a given key, or a mask value an UPDATE cannot hold
      def mask_update_statements(results, table, primary_key_values, extra_assignments = {})
        masked = masked_columns(table)
        extras = extra_assignments.reject { |name, _| masked.any? { |c| c.name == name } }.map do |name, value|
          "#{quote_identifier(name)} = #{extra_literal(table, name, value)}"
        end
        pk_index = table.columns.index { |c| c.name == table.primary_key }
        masked_indexes = masked.map { |c| table.columns.index(c) }
        given_by_key = primary_key_values.to_h { |v| [v.to_s, v] }
        given_folded = primary_key_values.to_set { |v| v.to_s.downcase }

        found = Set.new
        statements = results.map do |row|
          returned = row[pk_index]
          # MySQL converts a string like '12x' to 12 when comparing with an integer key, so such a row is not the one asked for.
          unless given_by_key.key?(returned.to_s) || given_folded.include?(returned.to_s.downcase)
            raise MaskUpdateRunner::Error,
                  "'#{table.name}' row with primary key #{returned.inspect} matched none of the given values exactly " \
                  "(#{primary_key_values.map(&:to_s).first(5).join(', ')}#{primary_key_values.size > 5 ? ', ...' : ''}); " \
                  "the database converted one of them, so pass the exact primary key values"
          end

          found << returned.to_s.downcase
          assignments = masked.each_with_index.map do |c, i|
            "#{quote_identifier(c.name)} = #{literal_for(table, c, row[masked_indexes[i]])}"
          end
          update_statement(table, assignments + extras, [given_by_key.fetch(returned.to_s, returned)])
        end

        [statements, statements.size, primary_key_values.reject { |v| found.include?(v.to_s.downcase) }]
      end

      # Writes a statement of #mask_update_statements as one line of SQL.
      #
      # @param io [#puts] where the statement is written
      # @param statement [String] an UPDATE statement
      # @return [void]
      def write_mask_update(io, statement)
        io.puts statement
      end

      private def masked_columns(table)
        table.columns.select { |c| mask_declared?(c) }
      end

      private def mask_declared?(column)
        column.raw_sql || !column.replace_with.nil? || column.map || column.replace_with_fake_data
      end

      # NULL, or one of the adapter's RANDOM_SECRET_PATTERNS (evaluated per row by the SELECT, then written as a literal).
      private def safe_for_credential?(column)
        sql = column.raw_sql.to_s.strip
        sql.casecmp?("NULL") || random_secret_expression?(sql)
      end

      private def random_secret_expression?(sql)
        self.class::RANDOM_SECRET_PATTERNS.any? do |pattern|
          match = pattern.match(sql)
          match && (match.names.empty? || RANDOM_BYTES_RANGE.cover?(match[:bytes].to_i))
        end
      end

      # A Time is written in its own zone without an offset (pass it in the zone the column stores), a Date as a date.
      private def extra_literal(table, name, value)
        value =
          case value
          # DateTime before Date: it is a Date subclass, and would lose its time there.
          when Time, DateTime then value.strftime("%Y-%m-%d %H:%M:%S.%6N")
          when Date then value.strftime("%Y-%m-%d")
          else value
          end
        escape_value(value)
      rescue UnsupportedValueError => e
        raise MaskUpdateRunner::Error, "'#{table.name}.#{name}' cannot be set to this value: #{e.message}"
      end

      private def literal_for(table, column, value)
        escape_value(value)
      rescue UnsupportedValueError => e
        raise MaskUpdateRunner::Error, "'#{table.name}.#{column.name}' cannot be masked to this value: #{e.message}"
      end

      private def update_statement(table, assignments, primary_key_values)
        where = QueryAst::WhereClause.new(column_name: table.primary_key, operator: :eq, value: primary_key_values)
        "UPDATE #{quote_table_name(table.name)} SET #{assignments.join(', ')} " \
          "WHERE #{compile_where_condition(where, table.name)};"
      end
    end
  end
end
