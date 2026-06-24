# frozen_string_literal: true

module AstFactory
  QueryAst = Exwiw::QueryAst

  # Require adapter_name declared on spec context.

  def build_select_shops_ast
    shops_table = shops_table(adapter_name)

    QueryAst::Select.new.tap do |ast|
      ast.from(shops_table.name)
      ast.select(shops_table.columns)
      ast.where(
        QueryAst::WhereClause.new(
          column_name: "id",
          operator: :eq,
          value: [1],
        )
      )
    end
  end

  def build_select_users_ast(filter_opt = nil)
    users_table = users_table(adapter_name)

    QueryAst::Select.new.tap do |ast|
      ast.from(users_table.name)
      ast.select(users_table.columns)
      ast.where(
        QueryAst::WhereClause.new(
          column_name: "shop_id",
          operator: :eq,
          value: [1],
        )
      )
      ast.where(filter_opt) if filter_opt
    end
  end

  # A select whose masked column (`nickname`) carries a `replace_with` template
  # that references a DIFFERENT column (`{email}`). Used to assert the
  # NULL-preserving guard keys off the masked column itself, not the referenced
  # one. Adapter-agnostic (the config is built inline, not loaded per adapter).
  def build_select_masked_reference_ast
    table = Exwiw::TableConfig.from_symbol_keys(
      name: "accounts",
      primary_key: "id",
      belongs_tos: [],
      columns: [
        { name: "id" },
        { name: "nickname", replace_with: "user-{email}" },
        { name: "email" },
      ],
    )

    QueryAst::Select.new.tap do |ast|
      ast.from(table.name)
      ast.select(table.columns)
    end
  end

  def build_join_query_ast
    order_items_table = order_items_table(adapter_name)

    QueryAst::Select.new.tap do |ast|
      ast.from(order_items_table.name)
      ast.select(order_items_table.columns)
      ast.join(
        QueryAst::JoinClause.new(
          base_table_name: "order_items",
          foreign_key: "order_id",
          join_table_name: "orders",
          primary_key: "id",
          where_clauses: [
            QueryAst::WhereClause.new(
              column_name: "shop_id",
              operator: :eq,
              value: [1],
            ),
          ],
        )
      )
    end
  end

  def build_transactions_two_join_ast
    transactions_table = transactions_table(adapter_name)

    QueryAst::Select.new.tap do |ast|
      ast.from(transactions_table.name)
      ast.select(transactions_table.columns)
      ast.join(
        QueryAst::JoinClause.new(
          base_table_name: "transactions",
          foreign_key: "order_id",
          join_table_name: "orders",
          primary_key: "id",
          where_clauses: [],
        )
      )
      ast.join(
        QueryAst::JoinClause.new(
          base_table_name: "orders",
          foreign_key: "shop_id",
          join_table_name: "shops",
          primary_key: "id",
          where_clauses: [
            QueryAst::WhereClause.new(
              column_name: "id",
              operator: :eq,
              value: [1],
            ),
          ],
        )
      )
    end
  end

  # comments が posts へ polymorphic belongs_to (commentable) しているケース。
  # 型カラム commentable_type は結合元テーブル (comments) 側にあるため
  # base_where_clauses に乗る。posts への FK 絞り込みは where_clauses (= 結合先)。
  def build_comments_polymorphic_join_ast
    QueryAst::Select.new.tap do |ast|
      ast.from("comments")
      ast.select_all!
      ast.join(
        QueryAst::JoinClause.new(
          base_table_name: "comments",
          foreign_key: "commentable_id",
          join_table_name: "posts",
          primary_key: "id",
          where_clauses: [
            QueryAst::WhereClause.new(
              column_name: "user_id",
              operator: :eq,
              value: [1],
            ),
          ],
          base_where_clauses: [
            QueryAst::WhereClause.new(
              column_name: "commentable_type",
              operator: :eq,
              value: ["Post"],
            ),
          ],
        )
      )
    end
  end

  # A multi-referencer reverse-scope query: `users` constrained to the UNION of
  # two scoped referencers' projected foreign keys, each excluding NULLs. Built
  # directly (not via the builder) so the adapter's UnionSubquery + :not_null
  # compilation can be asserted in isolation. Adapter-agnostic.
  def build_reverse_scope_union_ast
    arm = lambda do |table_name|
      QueryAst::Select.new.tap do |q|
        q.from(table_name)
        q.select([Exwiw::TableColumn.from_symbol_keys(name: "user_id")])
        q.where(QueryAst::WhereClause.new(column_name: "business_entity_id", operator: :eq, value: [1]))
        q.where(QueryAst::WhereClause.new(column_name: "user_id", operator: :not_null))
      end
    end

    QueryAst::Select.new.tap do |ast|
      ast.from("users")
      ast.select_all!
      ast.where(
        QueryAst::WhereClause.new(
          column_name: "id",
          operator: :in_subquery,
          value: QueryAst::UnionSubquery.new(queries: [arm.call("customers"), arm.call("staff")]),
        )
      )
    end
  end

  # A multi-hop forward scope cascade: `projects` constrained to `teams`,
  # `teams` to `companies`, and `companies` to a reverse_scope UNION. This is the
  # shape the builder emits when a table sits two `belongs_to` hops below a
  # reverse-scoped table, so it exercises a SelectSubquery nested inside a
  # SelectSubquery nested inside a UnionSubquery — i.e. recursive subquery
  # rendering at three levels. Built directly (not via the builder) so each
  # adapter's nesting can be asserted in isolation. Adapter-agnostic.
  def build_multi_hop_nested_in_ast
    plain = ->(name) { Exwiw::TableColumn.from_symbol_keys(name: name) }

    # Deepest level: the reverse_scope arm `companies` is constrained to.
    union_arm = QueryAst::Select.new.tap do |q|
      q.from("memberships")
      q.select([plain.call("company_id")])
      q.where(QueryAst::WhereClause.new(column_name: "business_entity_id", operator: :eq, value: [1]))
      q.where(QueryAst::WhereClause.new(column_name: "company_id", operator: :not_null))
    end

    companies_query = QueryAst::Select.new.tap do |q|
      q.from("companies")
      q.select([plain.call("id")])
      q.where(
        QueryAst::WhereClause.new(
          column_name: "id",
          operator: :in_subquery,
          value: QueryAst::UnionSubquery.new(queries: [union_arm]),
        )
      )
    end

    teams_query = QueryAst::Select.new.tap do |q|
      q.from("teams")
      q.select([plain.call("id")])
      q.where(
        QueryAst::WhereClause.new(
          column_name: "company_id",
          operator: :in_subquery,
          value: QueryAst::SelectSubquery.new(query: companies_query),
        )
      )
    end

    QueryAst::Select.new.tap do |ast|
      ast.from("projects")
      ast.select_all!
      ast.where(
        QueryAst::WhereClause.new(
          column_name: "team_id",
          operator: :in_subquery,
          value: QueryAst::SelectSubquery.new(query: teams_query),
        )
      )
    end
  end

  # A reverse-scope UNION over tables that actually exist in the seed, so it can
  # be executed and EXPLAINed against the real databases (the customers/staff
  # fixtures above are compile-only). `users` is constrained to the union of two
  # real referencers — orders (scoped to shop 1) and reviews — mirroring the
  # global-identity shape that motivated materializing the id-set: the old
  # `id IN (… UNION …)` form degrades into a per-row correlated DEPENDENT
  # SUBQUERY on a large `users`, which the derived-table JOIN removes.
  def build_users_reverse_scope_over_seed_ast
    plain = ->(name) { Exwiw::TableColumn.from_symbol_keys(name: name) }

    orders_arm = QueryAst::Select.new.tap do |q|
      q.from("orders")
      q.select([plain.call("user_id")])
      q.where(QueryAst::WhereClause.new(column_name: "shop_id", operator: :eq, value: [1]))
      q.where(QueryAst::WhereClause.new(column_name: "user_id", operator: :not_null))
    end
    reviews_arm = QueryAst::Select.new.tap do |q|
      q.from("reviews")
      q.select([plain.call("user_id")])
      q.where(QueryAst::WhereClause.new(column_name: "user_id", operator: :not_null))
    end

    QueryAst::Select.new.tap do |ast|
      ast.from("users")
      ast.select_all!
      ast.where(
        QueryAst::WhereClause.new(
          column_name: "id",
          operator: :in_subquery,
          value: QueryAst::UnionSubquery.new(queries: [orders_arm, reviews_arm]),
        )
      )
    end
  end

  # The pre-fix `<col> IN (… UNION …)` shape of #build_users_reverse_scope_over_seed_ast,
  # projected to just the id. Used as the control in result-set equivalence and
  # EXPLAIN before/after assertions — the derived-table JOIN must return the same
  # rows while no longer compiling to a correlated subquery.
  def users_reverse_scope_over_seed_in_sql
    "SELECT users.id FROM users WHERE users.id IN (" \
      "SELECT orders.user_id FROM orders WHERE orders.shop_id = 1 AND orders.user_id IS NOT NULL " \
      "UNION " \
      "SELECT reviews.user_id FROM reviews WHERE reviews.user_id IS NOT NULL)"
  end

  def build_order_items_ast(order_items_filter_opt = nil, orders_filter_opt = nil)
    order_items_table = order_items_table(adapter_name)

    QueryAst::Select.new.tap do |ast|
      ast.from(order_items_table.name)
      ast.select(order_items_table.columns)
      ast.where(order_items_filter_opt) if order_items_filter_opt
      ast.join(
        QueryAst::JoinClause.new(
          base_table_name: "order_items",
          foreign_key: "order_id",
          join_table_name: "orders",
          primary_key: "id",
          where_clauses: [
            QueryAst::WhereClause.new(
              column_name: "shop_id",
              operator: :eq,
              value: [1],
            ),
            orders_filter_opt,
          ].compact,
        )
      )
    end
  end
end
