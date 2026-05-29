# Plan: `schema:generate` で Rails 管理テーブル（`schema_migrations` / `ar_internal_metadata`）を出力する

## Context（背景）

`Exwiw::SchemaGenerator` は現状 `ActiveRecord::Base.descendants` を辿って dumpable なテーブルを列挙している。`schema_migrations` や `ar_internal_metadata` のような Rails が内部で管理するテーブルは **AR モデルが存在しない** ため、生成される config に出てこず、結果として dump 出力にも含まれない。マイグレーション履歴や Rails のメタ情報を含めたい利用者は JSON を手書きする必要がある。

本変更では、Rails の標準アクセサ（`ActiveRecord::Base.schema_migrations_table_name` と `ActiveRecord::Base.internal_metadata_table_name`）からテーブル名を取得して、それぞれ `schema_migrations.json` / `ar_internal_metadata.json` を自動生成する。新しい `type` フィールドに `rails_managed_schema_migrations` / `rails_managed_internal_metadata` を付与し、この **type フィールドを唯一のトリガ**として `SELECT *` 形式の extract を行う。利用者はこれらのエントリに対して `columns` / `belongs_tos` / `primary_key` を定義できず、generator とロード時バリデーションでそれを保証する。

## Decisions（設計判断）

- **取得経路**：
  - `schema_migrations` → `ActiveRecord::Base.schema_migrations_table_name`（= `config.active_record.schema_migrations_table_name`）
  - `ar_internal_metadata` → `ActiveRecord::Base.internal_metadata_table_name`
  - どちらも Rails 6.1〜8.x で安定。
- **`type` と `comment` は `TableConfig` の汎用 optional フィールド**として追加する。
- **`type` の値は rails_managed_xxx 系で 2 種類**：
  - `rails_managed_schema_migrations`
  - `rails_managed_internal_metadata`
  両者の挙動は同じだが、テーブルの役割が違うので type 値を分け、`TableConfig#rails_managed?` ヘルパで一括判定する。
- **rails_managed_xxx を唯一のトリガ**として以下を発行する：
  - extract 時は `SELECT *`（カラム列挙なし）
  - insert 時は `INSERT INTO <t> VALUES ...`（カラム列挙なし）
  - DELETE は生成しない
  通常テーブルで `columns: []` でも `SELECT *` にはしない（既存挙動を維持）。
- **rails_managed_xxx のときは `columns` / `belongs_tos` / `primary_key` を定義できない**。`TableConfig` ロード時に `ArgumentError` を上げる。
- **rails_managed_xxx の JSON 出力では `columns` / `belongs_tos` / `primary_key` フィールドを出さない**。
  - `primary_key` は optional 化することで `skip_serializing_if_nil` が効く → 自動的に消える。
  - `belongs_tos` / `columns` は required な配列なので Serdes 標準では空配列が出てしまう。`TableConfig#to_hash` を override して `rails_managed?` のときだけ両キーを strip する。ラウンドトリップのため属性宣言に `default: []` を付け、欠落 JSON も `[]` でロードできるようにする。
- **`primary_key` を optional 化**する（rails_managed_xxx で省略可）。非 rails_managed では presence をロード時にバリデーション（既存挙動を壊さない）。
- **`merge` の所有関係**: `type` は generator 由来。`comment` は receiver 由来（`filter` と対称）。

## Critical files（主に変更するファイル）

| File | 変更内容 |
|---|---|
| `lib/exwiw/table_config.rb` | `type` / `comment` 属性追加、`primary_key` を optional 化、`rails_managed?` 追加、ロード時バリデーション、`merge` 更新 |
| `lib/exwiw/schema_generator.rb` | descendants ループの後に rails-managed エントリ群を append |
| `lib/exwiw/query_ast.rb` | `QueryAst::Select` に `select_all` モードを追加 |
| `lib/exwiw/query_ast_builder.rb` | rails-managed テーブルを `select_all` モードに振り分け |
| `lib/exwiw/runner.rb` | `table.rails_managed?` のとき DELETE 生成をスキップ |
| `lib/exwiw/adapter/mysql2_adapter.rb` | `compile_ast` が `select_all` を尊重、`to_bulk_insert` は `table.rails_managed?` で分岐 |
| `lib/exwiw/adapter/postgresql_adapter.rb` | 同上 |
| `lib/exwiw/adapter/sqlite3_adapter.rb` | 同上 |
| `spec/schema_generator_spec.rb` | スナップショット列挙に 2 つ追加 |
| `spec/schema_output_snapshots/schema_migrations.json` | 新規 |
| `spec/schema_output_snapshots/ar_internal_metadata.json` | 新規 |
| `spec/table_config_spec.rb` | `type` / `comment` / `primary_key` optional / merge / バリデーションをカバー |
| `CHANGELOG.md` | Unreleased エントリ |

## Implementation（実装方針）

### 1. `lib/exwiw/table_config.rb`

属性宣言を更新。`primary_key` を optional 化し、`type` / `comment` を追加。`belongs_tos` / `columns` には `default: []` を付与してラウンドトリップを担保：

```ruby
attribute :name, String
attribute :primary_key, optional(String), skip_serializing_if_nil: true  # ← optional化
attribute :type, optional(String), skip_serializing_if_nil: true          # 新規
attribute :comment, optional(String), skip_serializing_if_nil: true       # 新規
attribute :filter, optional(String), skip_serializing_if_nil: true
attribute :belongs_tos, array(BelongsTo), default: []                      # ← default追加
attribute :columns, array(TableColumn), default: []                        # ← default追加
attribute :bulk_insert_chunk_size, optional(Integer), skip_serializing_if_nil: true
attribute :skip, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true
```

`to_hash` を override して、rails_managed のときは `belongs_tos` / `columns` を JSON 出力から取り除く（`primary_key` は optional 化により自動で省略される）：

```ruby
def to_hash
  hash = super
  if rails_managed?
    hash.delete("belongs_tos")
    hash.delete("columns")
  end
  hash
end
```

定数と判定ヘルパ：

```ruby
RAILS_MANAGED_SCHEMA_MIGRATIONS = "rails_managed_schema_migrations"
RAILS_MANAGED_INTERNAL_METADATA = "rails_managed_internal_metadata"
RAILS_MANAGED_TYPES = [
  RAILS_MANAGED_SCHEMA_MIGRATIONS,
  RAILS_MANAGED_INTERNAL_METADATA,
].freeze

def rails_managed?
  RAILS_MANAGED_TYPES.include?(type)
end
```

ロード時バリデーション。`from` を override して全構築経路を通す：

```ruby
def self.from(hash)
  config = super
  config.send(:validate_after_load!)
  config
end

private def validate_after_load!
  if rails_managed?
    raise ArgumentError, "Table '#{name}' has type=#{type}; primary_key must not be defined." if primary_key
    raise ArgumentError, "Table '#{name}' has type=#{type}; belongs_tos must not be defined." if !belongs_tos.empty?
    raise ArgumentError, "Table '#{name}' has type=#{type}; columns must not be defined." if !columns.empty?
  else
    raise ArgumentError, "Table '#{name}' requires primary_key." if primary_key.nil?
  end
end
```

`merge`（lines 70–94）を更新：
- `merged_table.type = passed_table.type`（generator 由来）
- `merged_table.comment = comment`（receiver 由来、`filter` と対称）

`build_extract_query`（lines 27–68）はそのまま放置（dead code、別件で削除）。

### 2. `lib/exwiw/schema_generator.rb`

ヘルパーを切り出して `build_tables` で concat：

```ruby
def build_tables
  models = concrete_models
  validate_single_database!(models)

  tables_from_models = models.group_by(&:table_name).map do |table_name, model_group|
    representative = model_group.first
    TableConfig.from_symbol_keys(
      name: table_name,
      primary_key: representative.primary_key,
      belongs_tos: aggregate_belongs_tos(model_group),
      columns: representative.column_names.map { |name| { name: name } },
    )
  end

  tables_from_models + build_rails_managed_tables
end

private def build_rails_managed_tables
  conn = ActiveRecord::Base.connection
  result = []

  schema_migrations_name = ActiveRecord::Base.schema_migrations_table_name
  if conn.table_exists?(schema_migrations_name)
    result << TableConfig.from_symbol_keys(
      name: schema_migrations_name,
      type: TableConfig::RAILS_MANAGED_SCHEMA_MIGRATIONS,
      comment: "Managed internally by Rails. Tracks applied schema migrations.",
      belongs_tos: [],
      columns: [],
    )
  end

  internal_metadata_name = ActiveRecord::Base.internal_metadata_table_name
  if conn.table_exists?(internal_metadata_name)
    result << TableConfig.from_symbol_keys(
      name: internal_metadata_name,
      type: TableConfig::RAILS_MANAGED_INTERNAL_METADATA,
      comment: "Managed internally by Rails. Stores environment and schema metadata.",
      belongs_tos: [],
      columns: [],
    )
  end

  result
end
```

メモ：
- `table_exists?` で防御。マイグレーションを無効化したアプリでも壊れない。
- `primary_key` は省略（rails_managed_xxx の規約）。
- belongs_tos / columns は明示的に `[]` を渡す（Serdes の required な配列属性なので）。

### 3. `lib/exwiw/query_ast.rb`

`QueryAst::Select` に `select_all` フラグを追加：

```ruby
class Select
  attr_reader :from_table_name, :columns, :where_clauses, :join_clauses, :select_all

  def initialize
    @from_table_name = nil
    @columns = []
    @where_clauses = []
    @join_clauses = []
    @select_all = false
  end

  def select_all!
    @select_all = true
  end
  # ... 他のメソッドはそのまま ...
end
```

opt-in なフラグ。default false なので既存挙動には影響しない。

### 4. `lib/exwiw/query_ast_builder.rb`

line 24–29 で rails-managed テーブルのときにフラグを立てる：

```ruby
QueryAst::Select.new.tap do |ast|
  ast.from(table.name)
  if table.rails_managed?
    ast.select_all!
  else
    ast.select(table.columns)
  end
  join_clauses.each { |join_clause| ast.join(join_clause) }
  where_clauses.each { |where_clause| ast.where(where_clause) }
end
```

rails-managed テーブルは `belongs_tos` が空なので、`build_where_clauses` も `build_join_clauses` も自然に空配列を返す。`build_where_clauses` の `table.primary_key` 参照（line 80）は `table.name == dump_target.table_name` のときだけ動くが、rails-managed テーブルは dump_target にできない（後述の防御）。

### 5. `lib/exwiw/runner.rb`

DELETE 生成をスキップ（line 97）：

```ruby
if adapter.supports_bulk_delete? && !@insert_only && !table.rails_managed?
  # ... 既存の DELETE ブロック ...
end
```

`validate_skipped`（line 132）と `dumpable?` フィルタ（line 41）は変更不要。rails-managed テーブルは `belongs_tos` が空で、何にも参照されないし、`ordered_tables` に残しておかないと `dump_schema` で DDL が出力されないため。

`@dump_target` の防御として、line 149 付近の `skip` チェックと同様に rails-managed テーブルを target に指定された場合のチェックを追加：

```ruby
if @dump_target.table_name && (target = configs.find { |c| c.name == @dump_target.table_name }) && target.rails_managed?
  raise ArgumentError,
        "--target-table '#{@dump_target.table_name}' is a Rails-managed table and cannot be used as a dump target."
end
```

### 6. Adapter 変更（mysql2 / postgresql / sqlite3）

3 つの SQL アダプタで同じパターン。

**`compile_ast`** — SELECT のカラムリスト部分（mysql2:144, postgresql:181, sqlite3:131）：

```ruby
sql += if query_ast.select_all
         "*"
       else
         query_ast.columns.map { |col| compile_column_name(query_ast, col) }.join(', ')
       end
```

**`to_bulk_insert`** — カラム名 join 部分（mysql2:90, postgresql:87/92, sqlite3:77）。`table.rails_managed?` で分岐：

```ruby
if table.rails_managed?
  "INSERT INTO #{table_name} VALUES\n#{values};"
else
  column_names = table.columns.map(&:name).join(', ')
  "INSERT INTO #{table_name} (#{column_names}) VALUES\n#{values};"
end
```

`to_bulk_delete` は Runner 側でガードしているので rails-managed では到達しない。変更不要。

PostgreSQL の `post_insert_sql`（postgresql_adapter.rb:114–129）は安全。`pg_get_serial_sequence` の引数に渡しても nil を返して no-op。

### 7. Tests

**`spec/schema_output_snapshots/schema_migrations.json`**（新規）：

```json
{
  "name": "schema_migrations",
  "type": "rails_managed_schema_migrations",
  "comment": "Managed internally by Rails. Tracks applied schema migrations."
}
```

**`spec/schema_output_snapshots/ar_internal_metadata.json`**（新規）：

```json
{
  "name": "ar_internal_metadata",
  "type": "rails_managed_internal_metadata",
  "comment": "Managed internally by Rails. Stores environment and schema metadata."
}
```

`primary_key` / `belongs_tos` / `columns` キーは JSON から完全に省略される。

key の順序は `TableConfig` の attribute 宣言順に揃える（`spec/schema_generator_spec.rb:223` の snapshot 一致テストで落ちないように）。

**`spec/schema_generator_spec.rb`** — line 188–191 の `contain_exactly` に `"schema_migrations.json"` と `"ar_internal_metadata.json"` を追加。line 211–225 の snapshot テストは新 fixture を自動的に拾う。

**`spec/table_config_spec.rb`** — 以下を追加：
- merge が user 設定の `comment` を保持する
- merge が `type` を常に generator 値で上書きする
- `type: rails_managed_*` で `columns` 非空のロード → `ArgumentError`
- `type: rails_managed_*` で `belongs_tos` 非空のロード → `ArgumentError`
- `type: rails_managed_*` で `primary_key` 指定あり → `ArgumentError`
- 非 rails_managed で `primary_key` 欠落 → `ArgumentError`（既存挙動の維持確認）
- rails_managed の `to_hash` 出力に `belongs_tos` / `columns` / `primary_key` キーが含まれないこと
- rails_managed の JSON（これらキー欠落）が round-trip でロードできること

**Adapter / query specs** — rails-managed 経路：
- `query_ast.select_all` true → `SELECT *`
- `table.rails_managed?` true → `INSERT INTO t VALUES (...)`（カラムリストなし）
- **通常テーブル**で `columns: []` のとき `SELECT *` には**ならない**（negative test）

### 8. `CHANGELOG.md`

Unreleased エントリ：

```
- schema:generate が Rails 管理テーブル（`schema_migrations` と `ar_internal_metadata`）の config を自動生成するようになった。それぞれ `type: "rails_managed_schema_migrations"` / `"rails_managed_internal_metadata"` を付与し、extract は `SELECT *`、INSERT はカラムリスト省略、DELETE は生成しない。これらのエントリでは `primary_key` / `columns` / `belongs_tos` を定義するとロード時に拒否される。
- TableConfig に optional な `type` / `comment` フィールドを追加。`primary_key` を optional に変更（非 rails_managed では依然必須）。
```

## Verification（確認手順）

1. **Unit spec**: `bundle exec rspec spec/schema_generator_spec.rb spec/table_config_spec.rb spec/query_ast_builder_spec.rb`
2. **全体テスト**: `bundle exec rspec` — adapter の rails-managed SQL 生成と通常テーブルの挙動非破壊を確認。
3. **dummy アプリでの end-to-end**:
   - `cd spec/dummy && bin/rails db:migrate`
   - リポジトリルートで `rake exwiw:schema:generate OUTPUT_DIR_PATH=tmp/schema`
   - `tmp/schema/schema_migrations.json` と `tmp/schema/ar_internal_metadata.json` が想定の形（primary_key/columns/belongs_tos なし or 空）で出力されることを確認。
   - `tmp/schema/schema_migrations.json` に手動で `primary_key` を足して dump 系コマンドを叩くとバリデーションエラーが出ることを確認。
   - 適当な target テーブル指定で dump を実行：
     - `insert-NNN-schema_migrations.sql` / `insert-NNN-ar_internal_metadata.sql` が `INSERT INTO t VALUES (...);` 形式（カラムリストなし）になる
     - 対応する `delete-NNN-*.sql` が生成されないことを確認
4. **Snapshot diff**: `git diff spec/schema_output_snapshots/` — 新規 2 ファイルのみ差分として出る。

## Out of scope（やらないこと）

- INSERT の重複ハンドリング（`ON CONFLICT DO NOTHING` 等）— 別件。
- dead code `TableConfig#build_extract_query` の削除 — 別件。
- アダプタ側の per-table フック（`supports_bulk_delete_for?` 等）— 必要になったら導入。
- 非 rails_managed テーブルからの `columns: []` / `belongs_tos: []` 省略 — 既存スナップショット（`shops.json` でも `"belongs_tos": []` が出ている）と整合させるため、空配列はそのまま出す。省略は rails_managed のみ。
