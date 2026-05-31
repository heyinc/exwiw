# frozen_string_literal: true

module Exwiw
  module DetermineTableProcessingOrder
    module_function

    # @param tables [Array<Exwiw::TableConfig>] tables
    # @return [Array<String>] sorted table names
    def run(tables)
      return tables.map(&:name) if tables.size < 2

      ordered_table_names = []

      table_by_name = tables.each_with_object({}) do |table, acc|
        acc[table.name] = table
      end

      loop do
        break if table_by_name.empty?

        tables_with_no_dependencies = table_by_name.values.select do |table|
          not_resolved_names = compute_table_dependencies(table) - ordered_table_names - [table.name]

          not_resolved_names.empty?
        end

        if tables_with_no_dependencies.empty?
          raise ArgumentError, build_cycle_error_message(table_by_name, ordered_table_names)
        end

        tables_with_no_dependencies.each do |table|
          ordered_table_names << table.name
          table_by_name.delete(table.name)
        end
      end

      ordered_table_names
    end

    def compute_table_dependencies(table)
      table.belongs_tos.each_with_object([]) do |relation, acc|
        acc << relation.table_name
      end
    end

    # When no table can be resolved but some remain, the belongs_to graph
    # contains a cycle (e.g. A belongs_to B and B belongs_to A). A topological
    # order cannot exist, so report the offending tables instead of looping
    # forever.
    private_class_method def cycle_diagnostics(table_by_name, ordered_table_names)
      table_by_name.values.map do |table|
        unresolved = (compute_table_dependencies(table) - ordered_table_names - [table.name]).uniq
        "  #{table.name} -> #{unresolved.join(', ')}"
      end
    end

    private_class_method def build_cycle_error_message(table_by_name, ordered_table_names)
      "Circular belongs_to dependency detected among tables: " \
        "#{table_by_name.keys.sort.join(', ')}. " \
        "A processing order cannot be determined. " \
        "Remove one of the belongs_to entries forming the cycle.\n" \
        "Unresolved dependencies:\n" \
        "#{cycle_diagnostics(table_by_name, ordered_table_names).join("\n")}"
    end
  end
end
