# PostgreSQL COPY モードの SQL 妥当性を検証する scenario_test 追加

## Context

`exwiw` の PostgreSQL アダプターは `--output-format=copy` で `COPY ... FROM stdin;` 形式の出力に切り替えられる（`lib/exwiw/adapter/postgresql_adapter.rb:77-85`）。既存のテストでは:

- 単体テスト（`spec/adapter/postgresql_adapter_spec.rb:256-305`）が文字列フォーマットを検証
- ランナー統合テスト（`spec/runner_spec.rb:236-286`）がファイル構造を検証

しかし **生成された COPY-mode SQL を実際に `psql -f` で取り込めるかを検証する end-to-end テストが存在しない**。ユーザーは COPY モードで invalid な SQL が出ているのではと疑っており、それを実DBに対して検証したい。

既存の INSERT モードは `scenario/test_with_postgresql.sh` が `psql -f` での再取込まで含めて検証している。これに対応する COPY モード版が無い状態。

ゴール: COPY モード出力を実際に psql に食わせる E2E シナリオ + スナップショット回帰テストを追加し、潜在的な invalid SQL を表面化する。

## 変更ファイル

1. **新規** `scenario/test_with_postgresql_copy.sh` — E2E シェル
2. **修正** `spec/insert_output_snapshot_spec.rb` — COPY 用の SCENARIOS エントリと `snapshot_subdir` 対応
3. **修正** `.github/workflows/scenario.yml` — `with_postgres` ジョブに新ステップ
4. **新規** `spec/insert_output_snapshots/postgresql-copy/insert-*.sql` — `UPDATE_SNAPSHOTS=1` で自動生成

## 詳細

### 1. `scenario/test_with_postgresql_copy.sh`

`scenario/test_with_postgresql.sh` を雛形にして以下のみ差し替え:

- `FROM_DATABASE_NAME="exwiw_scenario_prod_db_copy"`
- `TO_DATABASE_NAME="exwiw_scenario_dev_db_copy"`（並列実行されても既存シナリオと衝突しない名前）
- `exe/exwiw` に `--output-format=copy` を追加
- `--output-dir=tmp/postgresql-copy` に変更
- `delete-*.sql` / `insert-*.sql` のループも `tmp/postgresql-copy/` を参照

`set -e` により、psql が COPY ブロックの構文/データエラーで終了したら即時失敗する。これがユーザーが疑う「invalid SQL」の検出ポイント。

末尾の検証（`INSERT INTO shops ... ` がオートインクリメントで通るか）はそのまま流用 — `to_copy_from_stdin` の後ろに付く `post_insert_sql`（sequence の setval）まで含めて検証される。

実行権限 `chmod +x` を付与（兄弟スクリプトに合わせる）。

### 2. `spec/insert_output_snapshot_spec.rb`

- 78 行目の `snapshot_dir` を `scenario[:snapshot_subdir] || scenario[:adapter]` に変更し、同一 adapter で複数シナリオを持てるようにする
- 76 行目の context ラベルに `output_format` がある場合のサフィックスを足して、rspec 出力で区別可能にする
- `SCENARIOS` 配列に以下を追加:

```ruby
{
  adapter: "postgresql",
  config_dir: "scenario/postgresql-schema",
  output_format: "copy",
  snapshot_subdir: "postgresql-copy",
  connection: { adapter: "postgresql", database_name: "exwiw_test",
                host: "127.0.0.1", port: 5432,
                user: "postgres", password: "test_password" },
},
```

86 行目の `scenario.fetch(:output_format, "insert")` は既に存在するので追加変更不要。`insert-000-schema.sql` の pg_dump 正規化（21-25 行）も同 adapter なのでそのまま効く。

### 3. `.github/workflows/scenario.yml`

`with_postgres` ジョブの「Run exwiw (from clean target DB)」ステップ（115 行目）の後に追加:

```yaml
      - name: Run exwiw (copy mode)
        run: scenario/test_with_postgresql_copy.sh
```

`postgres:17-alpine` サービスと `postgresql-client-17` インストールは既存ステップで完了済みなので追加不要。

### 4. スナップショット生成

```
UPDATE_SNAPSHOTS=1 bundle exec rspec spec/insert_output_snapshot_spec.rb
```

`spec/insert_output_snapshots/postgresql-copy/` 配下に `insert-000-schema.sql` + `insert-001-shops.sql` ... `insert-007-transactions.sql` 相当が生成される。これを git に含める。

## 検証手順

1. ローカルで `docker compose up -d postgres` を起動
2. `bash scenario/test_with_postgresql_copy.sh` を実行 — exit 0 ならば COPY モード SQL は psql 経由で valid。non-zero なら invalid SQL が表面化（その時点で原因を特定して別途修正）
3. `UPDATE_SNAPSHOTS=1 bundle exec rspec spec/insert_output_snapshot_spec.rb` でスナップショットを生成
4. `bundle exec rspec spec/insert_output_snapshot_spec.rb` を `UPDATE_SNAPSHOTS` 無しで再実行し、全シナリオ（sqlite3 / mysql2 / postgresql / postgresql-copy / mongodb）が通ることを確認
5. CI 上で `with_postgres` ジョブの新ステップ `Run exwiw (copy mode)` が通る（または invalid SQL を検出する）ことを確認

## 想定される結果の分岐

- **テストが通った場合**: ユーザーの疑いは（少なくとも seed データの範囲では）杞憂。回帰テストとして残り、今後 COPY モード周りの改修で SQL を壊した時に早期検出できる
- **テストが落ちた場合**: 落ち方（psql のエラーメッセージ）から原因を特定。修正は本プランの範囲外として別タスクで対応する（ユーザーに報告 → 方針決定 → 実装）
