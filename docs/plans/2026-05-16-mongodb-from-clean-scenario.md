# Plan: MongoDB の `insert-000-schema.js` を scenario で end-to-end 検証する

## Context

`lib/exwiw/adapter/mongodb_adapter.rb#dump_schema` は `insert-000-schema.js` に
`createCollection` / `createIndex` を書き出す実装を既に持っているが、scenario 側で
これを apply するパスが無く、CI でも検証できていなかった。具体的なギャップ:

1. `e2e/setup_with_mongodb.rb` は seed を `insert_many` で流すだけで、index を一切作っていない
2. その結果 `tmp/mongodb/insert-000-schema.js` は `createCollection` 行のみで `createIndex` が 0 行
3. `e2e/import_with_mongodb.rb` は `insert-*.jsonl` だけを glob して処理しており、`insert-000-schema.js` を一切実行しない

sqlite3 / mysql2 / postgresql で導入済みの「from clean DB から立ち上げる」流れと
MongoDB の `insert-000-schema.js` が連動していない状態だった (issue #16)。

## ゴール

- 空の target DB に対して `mongosh insert-000-schema.js` → `insert-*.jsonl` の順で適用する scenario を CI に乗せる
- source DB に代表的な index を作り、`dump_schema` が `createIndex` 行を実際に吐く状態を作る
- 生成された createIndex 行が mongosh で実際に通ること、target 側で index が round-trip することを検証
- 既存の snapshot test (`spec/insert_output_snapshot_spec.rb`) でも createIndex 行を固定化

## 変更内容

### scenario 層
| パス | 変更 |
|---|---|
| `e2e/setup_with_mongodb.rb` | seed 流し込みの後に 3 種類の代表的 index を作る (unique `shops.name` / plain `users.email` / 複合 `orders.shop_id+user_id`) |
| `e2e/import_with_mongodb.rb` | `--no-drop` と `--input-dir DIR` フラグを追加。from-clean は drop すると schema.js が作った index ごと消えてしまうため |
| `e2e/verify_with_mongodb.rb` | `--with-indexes` で target collection の index を assert (default scenario では import 時に drop されるのでスキップ) |
| `e2e/test_with_mongodb_from_clean.sh` (新規) | `mongosh dropDatabase` → exwiw 実行 → `mongosh insert-000-schema.js` → `import --no-drop --input-dir tmp/mongodb-clean` → `verify --with-indexes` |
| `.github/workflows/scenario.yml` | with_mongodb job に `mongodb-mongosh` install ステップと `test_with_mongodb_from_clean.sh` 実行ステップを追加。apt repo の codename は `jammy` 固定 (ubuntu-latest が noble に上がる前提) |

### snapshot test 層
| パス | 変更 |
|---|---|
| `spec/support/bootstrap_databases.rb` | scenario と同じ 3 index を bootstrap で作る |
| `spec/insert_output_snapshots/mongodb/insert-000-schema.js` | 3 つの `db.getCollection(...).createIndex(...)` 行が追加される形で再生成 |

## 設計上の判断

- **unique index は `users.email` ではなく `shops.name` に貼る**: seed の `users.email`
  は `user1@example.com` が 5 shop に重複するので unique にできない。`shops.name`
  ("Shop 1".."Shop 5") は seed 上一意なので unique 可。
- **既存 scenario への副作用を最小化**: `import_with_mongodb.rb` のデフォルト挙動は変えず
  `--no-drop` フラグで opt-in。既存 `test_with_mongodb.sh` は無修正で動く。
- **verify を 2 用途で兼用**: `--with-indexes` 切り替えで from-clean のみ index を見る。
  既存 scenario は drop→insert で index が無くなるため index 検証はスキップ。
- **CI への mongosh install**: `mongo:7` service container には mongosh があるが、
  ubuntu-latest 上の `mongosh` コマンドは別。MongoDB の apt repo (`mongodb-mongosh`
  パッケージ) を入れる。codename は `jammy` 固定 (MongoDB 7.0 repo が noble を
  carry していない時期があるため)。
- **snapshot fixture を indexes 入りに更新**: bootstrap_databases.rb と
  setup_with_mongodb.rb で同じ index を作るので、snapshot test と scenario test の
  期待値が分岐しない。

## Verification

- `bash e2e/test_with_mongodb.sh` 既存 scenario 維持を確認 ✓
- `bash e2e/test_with_mongodb_from_clean.sh` 新規 scenario 通過を確認
  (indexes round-trip OK) ✓
- `bundle exec rspec` 全 153 examples / 0 failures ✓
- `tmp/mongodb-clean/insert-000-schema.js` を目視で確認:
  ```js
  db.getCollection("shops").createIndex({"name":1}, {"unique":true,"name":"idx_shops_name"});
  db.getCollection("users").createIndex({"email":1}, {"name":"idx_users_email"});
  db.getCollection("orders").createIndex({"shop_id":1,"user_id":1}, {"name":"idx_orders_shop_user"});
  ```

## 留意点

- `import_with_mongodb.rb` のフラグ解析は手書きの ARGV パース。引数が増えるなら
  OptionParser 化を検討する余地あり (現状は 2 フラグなので過剰)。
- ubuntu-latest が将来 codename を変えても apt repo の `jammy` 指定は壊れない想定だが、
  MongoDB 8.x へ移行する際は repo URL の `7.0` も更新が必要。
- 既存 issue #16 のスコープは MongoDB のみ。SQL 系の from_clean は別 PR で導入済み。
