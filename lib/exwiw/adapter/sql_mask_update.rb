# frozen_string_literal: true

module Exwiw
  module Adapter
    # Mask-UPDATE generation shared by the SQL adapters. Including adapters provide
    # #fetch_rows(sql) (rows as arrays) plus the usual compile_* / escape_value helpers.
    module SqlMaskUpdate
      SELECT_ONLY = %r{\A\s*(?:/\*.*?\*/\s*)*SELECT\b}mi

      # A `random_bytes` of fewer bytes is guessable; more than the maximum is just wasteful.
      RANDOM_BYTES_RANGE = (16..1024)

      # @param table [Exwiw::TableConfig] table to mask
      # @param dump_target [Exwiw::DumpTarget] names the rows to mask by their primary keys (`default_ids`)
      # @param allow_constant_columns [Array<String>] credential-looking "table.column"s accepted as non-NULL masks
      # @return [Exwiw::MaskUpdatePlan::Generated]
      def build_mask_update(table, dump_target, _table_by_name = nil, allow_constant_columns: [])
        columns = table.columns.reject(&:ignore)
        masked = columns.select { |c| mask_declared?(c) }
        if masked.empty?
          raise MaskUpdatePlan::Error,
                "table '#{table.name}' declares no mask (replace_with / raw_sql / map / replace_with_fake_data) on any column"
        end
        if masked.any? { |c| c.name == table.primary_key }
          raise MaskUpdatePlan::Error,
                "table '#{table.name}' masks its primary key '#{table.primary_key}', which selects the rows to update"
        end

        masks = masked.map { |c| [c.name, safe_for_credential?(c)] }
        allowed = MaskUpdatePlan.check_credential_columns!(table.name, masks, allow_constant_columns)

        primary_key_values = dump_target.default_ids
        effective = table.dup.tap { |t| t.columns = columns }
        matched, statements = lookup_rows(effective, dump_target, columns, masked, primary_key_values)
        found = matched.to_set { |v| v.to_s.downcase }

        MaskUpdatePlan::Generated.new(
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

      # Rows are matched by what the database returns (a case-insensitive collation can return "abc" for "ABC").
      private def lookup_rows(effective, dump_target, columns, masked, primary_key_values)
        pk = effective.primary_key
        pk_column = columns.find { |c| c.name == pk } || TableColumn.from_symbol_keys(name: pk)
        select_columns = columns.include?(pk_column) ? columns : columns + [pk_column]
        pk_index = select_columns.index(pk_column)
        transformer = RowTransformer.build(effective)
        masked_indexes = masked.map { |c| columns.index(c) }
        computed = masked.map { |c| c.map || c.replace_with_fake_data }
        given_by_key = primary_key_values.to_h { |v| [v.to_s, v] }

        matched = []
        statements = []
        primary_key_values.each_slice(MaskUpdatePlan::CHUNK_SIZE) do |chunk|
          ast = QueryAst::Select.new
          ast.from(effective.name)
          ast.select(select_columns)
          ast.where(dump_target.target_where_clause(effective, ids: chunk))
          label = query_comment_text("mask-update table=#{effective.name}")
          rows = select_rows("/* #{label} */ #{compile_ast(ast)}")

          rows.each do |row|
            pk_value = given_by_key.fetch(row[pk_index].to_s, row[pk_index])
            matched << pk_value

            row = transformer.transform(row) if transformer
            assignments = masked.each_with_index.map do |c, i|
              value = row[masked_indexes[i]]
              value = writable_value(effective, c, value) if computed[i]
              "#{quote_identifier(c.name)} = #{escape_value(value)}"
            end
            statements << update_statement(effective, assignments, [pk_value])
          end
        end
        [matched.uniq, statements]
      end

      # escape_value embeds anything but a String verbatim, so a map must not return another type.
      private def writable_value(table, column, value)
        return value if value.nil? || value.is_a?(String) || value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)

        raise MaskUpdatePlan::Error,
              "'#{table.name}.#{column.name}' was masked to #{value.inspect} (#{value.class}); " \
              "only a String, Integer, finite Float or nil can be written into an UPDATE"
      end

      private def update_statement(table, assignments, primary_key_values)
        where = QueryAst::WhereClause.new(column_name: table.primary_key, operator: :eq, value: primary_key_values)
        "UPDATE #{quote_table_name(table.name)} SET #{assignments.join(', ')} " \
          "WHERE #{compile_where_condition(where, table.name)};"
      end

      private def select_rows(sql)
        raise MaskUpdatePlan::Error, "refusing to run a non-SELECT statement: #{sql[0, 40]}" unless sql.match?(SELECT_ONLY)

        fetch_rows(sql)
      end
    end
  end
end
