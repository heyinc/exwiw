# frozen_string_literal: true

# A tree table shared by the adapter specs that run its ancestor query live.
module SelfReferencingTree
  module_function

  # 3 -> 2 -> 1 (2 is also kept directly), 4 <-> 5 cycle, 6 has no parent, 7's
  # parent is missing, and only another tenant's product points at 8.
  KEPT_IDS = [1, 2, 3, 4, 5, 6, 7].freeze
  # Note 10x belongs to category x, so the ancestors' notes are kept too.
  KEPT_NOTE_IDS = KEPT_IDS.map { |id| 100 + id }.freeze

  DROP_STATEMENTS = [
    "DROP TABLE IF EXISTS tree_category_notes",
    "DROP TABLE IF EXISTS tree_products",
    "DROP TABLE IF EXISTS tree_categories",
  ].freeze

  def setup_statements(id_type:, text_type:)
    DROP_STATEMENTS + [
      "CREATE TABLE tree_categories (id #{id_type} PRIMARY KEY, parent_id #{id_type}, name #{text_type})",
      "CREATE TABLE tree_products (id #{id_type} PRIMARY KEY, tenant_id #{text_type}, category_id #{id_type})",
      "CREATE TABLE tree_category_notes (id #{id_type} PRIMARY KEY, category_id #{id_type})",
      "INSERT INTO tree_categories VALUES (1, NULL, 'root'), (2, 1, 'mid'), (3, 2, 'leaf'), " \
        "(4, 5, 'cycle a'), (5, 4, 'cycle b'), (6, NULL, 'lone'), (7, 99, 'orphan'), (8, NULL, 'unused')",
      "INSERT INTO tree_products VALUES (1, 't1', 3), (2, 't1', 2), (3, 't1', 4), (4, 't1', 6), " \
        "(5, 't1', 7), (6, 't2', 8)",
      "INSERT INTO tree_category_notes VALUES #{(1..8).map { |id| "(#{100 + id}, #{id})" }.join(', ')}",
    ]
  end

  def dump_target
    Exwiw::DumpTarget.new(ids: ['t1'], scope_column: 'tenant_id')
  end

  def table_by_name
    categories = Exwiw::TableConfig.from_symbol_keys(
      name: 'tree_categories', primary_key: 'id',
      belongs_tos: [{ table_name: 'tree_categories', foreign_key: 'parent_id' }],
      reverse_scope: { via: [{ table: 'tree_products', column: 'category_id' }] },
      columns: [{ name: 'id' }, { name: 'parent_id' }, { name: 'name' }]
    )
    products = Exwiw::TableConfig.from_symbol_keys(
      name: 'tree_products', primary_key: 'id',
      belongs_tos: [{ table_name: 'tree_categories', foreign_key: 'category_id' }],
      columns: [{ name: 'id' }, { name: 'tenant_id' }, { name: 'category_id' }]
    )
    notes = Exwiw::TableConfig.from_symbol_keys(
      name: 'tree_category_notes', primary_key: 'id',
      belongs_tos: [{ table_name: 'tree_categories', foreign_key: 'category_id' }],
      columns: [{ name: 'id' }, { name: 'category_id' }]
    )
    [categories, products, notes].to_h { |table| [table.name, table] }
  end

  def extraction_ast(table_name, logger)
    Exwiw::QueryAstBuilder.run(table_name, table_by_name, dump_target, logger)
  end
end
