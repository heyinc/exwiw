# frozen_string_literal: true

module Exwiw
  class TableConfig
    include Serdes

    attribute :name, String
    attribute :primary_key, String
    attribute :filter, optional(String), skip_serializing_if_nil: true
    attribute :belongs_tos, array(BelongsTo)
    attribute :columns, array(TableColumn)
    attribute :bulk_insert_chunk_size, optional(Integer), skip_serializing_if_nil: true
    attribute :skip, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true

    def self.from_symbol_keys(hash)
      from(JSON.parse(hash.to_json))
    end

    def column_names
      columns.map(&:name)
    end

    def belongs_to(table_name)
      belongs_tos.find { |relation| relation.table_name == table_name }
    end

    def build_extract_query(extract_target_table, extract_target_ids, tables_by_name)
      # target is itself
      if name == extract_target_table
        return [{
          from: name,
          where: [{ primary_key => extract_target_ids }],
          join: [],
          select: column_names,
        }]
      end

      # it is not related to target table
      if belongs_to.empty?
        return [{
          from: name,
          where: [],
          join: [],
          select: column_names,
        }]
      end

      belongs_to_extract_target_table = belongs_tos.find { |relation| relation.table_name == extract_target_table }
      if belongs_to_extract_target_table
        key = belongs_to_extract_target_table.foreign_key
        return [{ from: name, where: [{ key => extract_target_ids }], join: [], select: column_names }]
      end

      ret = compute_dependency_to_table(extract_target_table, tables_by_name)

      if ret.empty?
        [{
          from: name,
          where: [],
          join: [],
          select: column_names,
        }]
      else
        last = ret.last
        last[:where] = [{ last[:foreign_key] => extract_target_ids }]
        ret
      end
    end

    def merge(passed_table)
      return passed_table if passed_table.to_hash == self.to_hash


      TableConfig.new.tap do |merged_table|
        merged_table.name = name
        merged_table.primary_key = passed_table.primary_key
        merged_table.filter = filter
        merged_table.belongs_tos = passed_table.belongs_tos
        merged_table.bulk_insert_chunk_size = passed_table.bulk_insert_chunk_size
        merged_table.skip = skip

        receiver_column_by_name = columns.each_with_object({}) { |column, hash| hash[column.name] = column }

        merged_table.columns =
          passed_table.columns.map do |passed_column|
            if receiver_column_by_name.key?(passed_column.name)
              receiver_column = receiver_column_by_name[passed_column.name]
              receiver_column
            else
              passed_column
            end
          end
      end
    end

    private def compute_dependency_to_table(target_table_name, tables_by_name)
      return [] if belongs_tos.empty?

      results = belongs_tos.map do |relation|
        relation_table = tables_by_name[relation.table_name]

        if relation_table.name == target_table_name
          [{ base_table_name: name, foreign_key: relation.foreign_key,
             join_table_name: target_table_name, join_key: relation_table.primary_key }]
        else
          ret = relation_table.compute_dependency_to_table(target_table_name, tables_by_name)
          [{ base_table_name: name, foreign_key: relation.foreign_key,
             join_table_name: relation_table.name, join_key: relation_table.primary_key }] + ret
        end
      end.compact

      matched_dependencies = results.select do |dependency|
        dependency.last[:join_table_name] == target_table_name
      end

      return [] if matched_dependencies.empty?

      matched_dependencies.min_by(&:size)
    end
  end
end
