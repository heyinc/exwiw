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
