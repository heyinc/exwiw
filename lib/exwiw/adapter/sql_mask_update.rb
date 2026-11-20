# frozen_string_literal: true

module Exwiw
  module Adapter
    # Mask-UPDATE generation shared by the SQL adapters. Rows are read with the adapter's
    # #execute, as export does, so the only statements issued are the SELECTs of #build_query.
    module SqlMaskUpdate
      # A `random_bytes` of fewer bytes is guessable; more than the maximum is just wasteful.
      RANDOM_BYTES_RANGE = (16..1024)

      # @param table [Exwiw::TableConfig] table to mask
      # @param dump_target [Exwiw::DumpTarget] names the rows to mask by their primary keys (`default_ids`)
      # @param allow_constant_columns [Array<String>] credential-looking "table.column"s accepted as non-NULL masks
      # @return [Exwiw::MaskUpdateRunner::Generated]
      def build_mask_update(table, dump_target, table_by_name, allow_constant_columns: [])
        # ids are primary keys here even if the table declares a scope_column
        table = table.dup.tap do |t|
          t.columns = t.columns.reject(&:ignore)
          t.scope_column = nil
        end
        columns = table.columns
        masked = columns.select { |c| mask_declared?(c) }
        if masked.empty?
          raise MaskUpdateRunner::Error,
                "table '#{table.name}' declares no mask (replace_with / raw_sql / map / replace_with_fake_data) on any column"
        end
        if masked.any? { |c| c.name == table.primary_key }
          raise MaskUpdateRunner::Error,
                "table '#{table.name}' masks its primary key '#{table.primary_key}', which selects the rows to update"
        end

        masks = masked.map { |c| [c.name, safe_for_credential?(c)] }
        allowed = MaskUpdateRunner.check_credential_columns!(table.name, masks, allow_constant_columns)

        primary_key_values = dump_target.default_ids
        matched, statements = lookup_rows(table, dump_target, table_by_name.merge(table.name => table), masked, primary_key_values)
        found = matched.to_set { |v| v.to_s.downcase }

        MaskUpdateRunner::Generated.new(
          statements: statements,
          target_count: matched.size,
          columns: masked.map(&:name),
          missing_primary_key_values: primary_key_values.reject { |v| found.include?(v.to_s.downcase) },
          allowed_constant_columns: allowed,
        )
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

      # Selects with the query export builds for the target table, minus the ancestors it keeps for a
      # self-referencing table. Rows are matched by what the database returns (a case-insensitive
      # collation can return "abc" for "ABC").
      private def lookup_rows(table, dump_target, table_by_name, masked, primary_key_values)
        pk = table.primary_key
        transformer = RowTransformer.build(table)
        masked_indexes = masked.map { |c| table.columns.index(c) }
        computed = masked.map { |c| c.map || c.replace_with_fake_data }
        given_by_key = primary_key_values.to_h { |v| [v.to_s, v] }
        given_folded = primary_key_values.to_set { |v| v.to_s.downcase }

        matched = []
        statements = []
        primary_key_values.each_slice(MaskUpdateRunner::CHUNK_SIZE) do |chunk|
          target = dump_target.dup.tap { |t| t.ids = chunk }
          ast = build_query(table, target, table_by_name, self_ancestors: false)
          # The key goes after the table's columns, so the transformer's indexes still hold.
          ast.columns << QueryAst::ColumnValue::Plain.new(name: pk, value: pk) unless ast.columns.any? { |c| c.name == pk }
          pk_index = ast.columns.index { |c| c.name == pk }

          execute(ast).each do |row|
            returned = row[pk_index]
            # MySQL converts a string like '12x' to 12 when comparing with an integer key, so such a row is not the one asked for.
            unless given_by_key.key?(returned.to_s) || given_folded.include?(returned.to_s.downcase)
              raise MaskUpdateRunner::Error,
                    "'#{table.name}' row with primary key #{returned.inspect} matched none of the given values exactly " \
                    "(#{primary_key_values.map(&:to_s).first(5).join(', ')}#{primary_key_values.size > 5 ? ', ...' : ''}); " \
                    "the database converted one of them, so pass the exact primary key values"
            end

            pk_value = given_by_key.fetch(returned.to_s, returned)
            matched << pk_value

            row = transformer.transform(row) if transformer
            assignments = masked.each_with_index.map do |c, i|
              value = row[masked_indexes[i]]
              value = writable_value(table, c, value) if computed[i]
              "#{quote_identifier(c.name)} = #{escape_value(value)}"
            end
            statements << update_statement(table, assignments, [pk_value])
          end
        end
        [matched.uniq, statements]
      end

      # escape_value embeds anything but a String verbatim, so a map must not return another type.
      private def writable_value(table, column, value)
        return value if value.nil? || value.is_a?(String) || value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)

        raise MaskUpdateRunner::Error,
              "'#{table.name}.#{column.name}' was masked to #{value.inspect} (#{value.class}); " \
              "only a String, Integer, finite Float or nil can be written into an UPDATE"
      end

      private def update_statement(table, assignments, primary_key_values)
        where = QueryAst::WhereClause.new(column_name: table.primary_key, operator: :eq, value: primary_key_values)
        "UPDATE #{quote_table_name(table.name)} SET #{assignments.join(', ')} " \
          "WHERE #{compile_where_condition(where, table.name)};"
      end
    end
  end
end
