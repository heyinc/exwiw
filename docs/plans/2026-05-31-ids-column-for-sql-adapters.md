# `--ids-column` を SQL アダプタに実装

## Context

MongoDB アダプタには `--ids-field` フラグがあり、`--ids` を対象テーブルの主キー以外の
フィールドにマッチさせられる（`lib/exwiw/adapter/mongodb_adapter.rb:48-65`）。一方で
SQL アダプタ（mysql2 / postgresql / sqlite3）では未実装で、CLI が明示的に拒否している
（`lib/exwiw/cli.rb:183-189` の TODO、`lib/exwiw/query_ast_builder.rb:109-118` の TODO）。

このプランでは同等の機能を SQL アダプタにも提供する。命名・ゲーティングは既存の
`--target-table` / `--target-collection` の分け方を踏襲し、**アダプタ別に厳密分離**する:

- `--ids-field` … mongodb 専用（既存）
- `--ids-column` … SQL アダプタ専用（新規）
- 両方同時指定は拒否、不適合アダプタとの組み合わせも拒否

内部的には双方とも `DumpTarget#ids_field` に集約される（`--target-collection` が
`@target_table_name` に畳まれるのと同じパターン）。

## 変更内容

### 1. `lib/exwiw/cli.rb` — フラグ定義・畳み込み・バリデーション

- **インスタンス変数追加**（`initialize`, 42行目付近）: `@ids_column = nil` を追加。
- **フラグ定義**（`parser`, 309行目付近）: `--ids-field` の直後に追加。
  ```ruby
  opts.on("--ids-column=[COLUMN]", "Column on the target table that --ids is matched against. Defaults to the primary key. (sql adapters only)") { |v| @ids_column = v }
  ```
- **エイリアス畳み込み**: `resolve_target_collection_alias!`（210行目）に倣い
  `resolve_ids_column_alias!` を新設し `validate_options!` の冒頭で呼ぶ。挙動:
  - `--ids-field` と `--ids-column` の同時指定を拒否
    （"Specify only one of --ids-field and --ids-column"）。
  - `--ids-column` を mongodb で使った場合は拒否
    （"--ids-column is only supported by the sql adapters (use --ids-field)"）。
  - 問題なければ `@ids_field = @ids_column` に畳み込む。
- **`--ids-field` の検証更新**（175-190行目）:
  - `--target-table` 必須チェックは「`@ids_field` が立っていれば」で共通化されるため、
    畳み込み後はそのまま両方をカバーする（メッセージは ids_field/ids_column を
    使った側に合わせて出し分けるか、汎用文言にする — 実装時に調整）。
  - mongodb 限定チェック（186-189行目）は `--ids-field` 用に維持
    （"--ids-field is currently only supported by the mongodb adapter" のまま）。

  実装方針: 畳み込み前にどちらのフラグが使われたかが分かる状態で
  「target-table 必須」「アダプタ整合」を検証してから `@ids_field` に集約する。

### 2. `lib/exwiw/query_ast_builder.rb` — WHERE 句に反映

**当初の想定（1行変更）は関連テーブルで不正確になることが判明**したため、設計を変更した。
SQL アダプタは単一クエリで `dump_target.ids` を外部キーに直接伝播する
（`orders.user_id IN ids`）。これは `--ids` が主キーである前提のため、`--ids-column`
で別カラムを指定すると関連テーブルが壊れる（mongodb は @state に主キーを溜めて伝播する
ので正しい）。

採用したアプローチ: **ターゲットを介すサブクエリ**。`ids_field` 指定時、外部キー制約を
`fk IN (SELECT pk FROM target WHERE ids_field IN (ids))` に置き換える。direct /
indirect / polymorphic を一律に正しく扱える。

- `lib/exwiw/query_ast.rb`: `Subquery` 構造体を追加。`WhereClause` に
  operator `:in_subquery`（value が `Subquery`）を導入し `to_h` を対応。
- `lib/exwiw/query_ast_builder.rb`: `dump_target_fk_clause(foreign_key)` ヘルパーを新設。
  `ids_field` 無しなら従来通り `eq`、有りなら `:in_subquery` を返す。
  - `build_where_clauses`（direct belongs_to）と `build_join_clauses`
    （indirect の `relation_to_dump_target` hop）の両方で利用。
  - ターゲットテーブル自身のフィルタは `ids_field || primary_key` の `eq`（従来どおり）。
- 各 SQL アダプタ（postgresql / mysql2 / sqlite3）の `compile_where_condition` に
  `:in_subquery` 分岐と `compile_subquery` を追加。`is_a?(WhereClause)` のままなので
  bulk_delete のサブクエリ生成・JoinClause.to_h もそのまま動く。

補足: `--ids-column` がマスク対象カラムの場合、`delete-*` の冪等性が崩れる
（README に注記済み）。

## 検証

- `bundle exec rspec spec/cli_spec.rb` — 既存の `--ids-field` validation を維持しつつ、
  新規ケースを追加:
  - `--ids-column` が `@ids_field`（畳み込み後）にパースされる
  - `--ids-column` を mongodb で指定すると拒否される
  - `--ids-field` と `--ids-column` の同時指定が拒否される
  - `--ids-column` を target-table 無しで指定すると拒否される
- `bundle exec rspec spec/query_ast_builder_spec.rb`（存在すれば）に
  `ids_field` 指定時に対象テーブルの WHERE が主キーではなく当該カラムになることを確認する
  ケースを追加。
- `explain` サブコマンド（SQL のみ対応）で end-to-end 確認:
  既存 scenario（例 `e2e/sqlite3-schema`）に対し
  `--target-table=... --ids=... --ids-column=<col>` を渡し、出力 SQL の WHERE が
  `<table>.<col> IN (...)` になることを目視確認。
- `bundle exec rspec`（全体）でリグレッションが無いこと。

## ドキュメント

`README.md:415` の `--ids-field` 説明を更新し、SQL では `--ids-column` を使う旨と例
（例: `--target-table=users --ids=a@example.com --ids-column=email`）を追記。
「SQL adapters reject it / TODO」の記述を解消する。
