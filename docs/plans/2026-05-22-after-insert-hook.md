# Plan: `--after-insert-hook` フック (Ruby DSL / shell script)

## Context

現状 `exwiw` は `insert-000-schema.{sql,js}` → `insert-NNN-{table}.{sql,jsonl}` → `delete-NNN-...` を生成して終わる。実運用では「import 後に特定テナントへデフォルトユーザを挿入する」「監査ログを 1 行打つ」など、抽出結果を踏まえた**後処理 SQL / 副作用**を続けて流したいケースがある。

これを毎回別ファイルとして手で書き足すのは面倒なので、抽出ジョブの一部としてフックを記述できるようにする。フックは `--ids` などの CLI オプションを参照できるべき (例: 「抽出対象のテナント ID 配列に対してデフォルトユーザを seed」)。

ゴール:

- `--after-insert=PATH` オプションを追加。`PATH` には `.rb` または `.sh` を指定可。
- 拡張子 `.rb`: 軽量 DSL (`cli_options`, `insert_sql` / `insert_jsonl`) を提供。文字列引数は ERB として評価され、結果が連結されて最後尾の insert ファイルとして書き出される。
- 拡張子 `.sh` (および `.rb` 以外): 環境変数で CLI オプションを渡したうえで子プロセスとして実行。出力ファイルは生成しない (純粋な副作用フック)。
- フックは per-table の insert/delete ループ完了後に 1 度だけ実行される。

## Design

### CLI レイヤー
**File**: `lib/exwiw/cli.rb`

- `@after_insert_path = nil` を初期化 (`initialize`)。
- `parser` 内に `opts.on("--after-insert=[PATH]", "Path to a .rb or .sh post-processing hook") { |v| @after_insert_path = File.expand_path(v) }` を追加。
- `validate_options!` で以下を検証:
  - パスが存在しないとき: `$stderr.puts "--after-insert file not found: #{@after_insert_path}"; exit 1`
  - 拡張子が `.rb` でも `.sh` でもなく、かつ実行可能ビットも立っていないとき: `--after-insert must be a .rb file or an executable script` で exit 1。
- `cli_options` 用に **CLI 全オプションを Hash 化するメソッド** を追加 (`build_cli_options_hash`):
  ```ruby
  {
    database_host: @database_host, database_port: @database_port,
    database_user: @database_user, database_password: @database_password,
    output_dir: @output_dir, config_dir: @config_dir,
    database_adapter: @database_adapter, database_name: @database_name,
    target_table: @target_table_name, ids: @ids.dup.freeze,
    output_format: @output_format, insert_only: @insert_only,
    log_level: @log_level, after_insert: @after_insert_path,
  }.freeze
  ```
- `Runner.new(...)` 呼び出しに `after_insert_path: @after_insert_path, cli_options: build_cli_options_hash` を追加。

### Runner 統合
**File**: `lib/exwiw/runner.rb`

- `initialize` のキーワード引数に `after_insert_path: nil, cli_options: {}` を追加し instance var に格納。
- `run` の per-table ループ (`ordered_table_names.each_with_index`) が終わった**直後** (現状の line 98 の直後) で:
  ```ruby
  if @after_insert_path
    @logger.info("Running after-insert hook: #{@after_insert_path}")
    AfterInsertHook.run(
      path: @after_insert_path,
      cli_options: @cli_options,
      output_dir: @output_dir,
      next_idx: total_size + 1,
      output_extension: adapter.output_extension,
      logger: @logger,
    )
  end
  ```
- `total_size` は既存変数 (`ordered_table_names.size`)。schema が `000`、per-table が `001..total_size` を使うので、フック出力は `total_size + 1` 番。`delete-*` は逆順番号なので衝突しない。

### 新規ファイル: `lib/exwiw/after_insert_hook.rb`

```ruby
require 'erb'
require 'shellwords'

module Exwiw
  class AfterInsertHook
    def self.run(path:, cli_options:, output_dir:, next_idx:, output_extension:, logger:)
      ext = File.extname(path)
      idx_str = next_idx.to_s.rjust(3, '0')
      output_path = File.join(output_dir, "insert-#{idx_str}-after_insert.#{output_extension}")

      case ext
      when '.rb'
        run_ruby(path: path, cli_options: cli_options, output_path: output_path, logger: logger)
      else
        run_shell(path: path, cli_options: cli_options, output_dir: output_dir, logger: logger)
      end
    end

    def self.run_ruby(path:, cli_options:, output_path:, logger:)
      ctx = Context.new(cli_options)
      ctx.instance_eval(File.read(path), path)
      sql = ctx.collected.join("\n")
      if sql.empty?
        logger.info("After-insert hook produced no output; skipping file write.")
        return
      end
      File.write(output_path, sql)
      logger.info("Wrote after-insert hook output to #{output_path}")
    end

    def self.run_shell(path:, cli_options:, output_dir:, logger:)
      env = {
        'EXWIW_OUTPUT_DIR'       => output_dir,
        'EXWIW_CONFIG_DIR'       => cli_options[:config_dir].to_s,
        'EXWIW_DATABASE_ADAPTER' => cli_options[:database_adapter].to_s,
        'EXWIW_DATABASE_HOST'    => cli_options[:database_host].to_s,
        'EXWIW_DATABASE_PORT'    => cli_options[:database_port].to_s,
        'EXWIW_DATABASE_USER'    => cli_options[:database_user].to_s,
        'EXWIW_DATABASE_NAME'    => cli_options[:database_name].to_s,
        'EXWIW_TARGET_TABLE'     => cli_options[:target_table].to_s,
        'EXWIW_IDS'              => Array(cli_options[:ids]).join(','),
        'EXWIW_OUTPUT_FORMAT'    => cli_options[:output_format].to_s,
      }
      # DATABASE_PASSWORD は既存 ENV をそのまま受け継がせる (env hash で上書きしない)。
      ok = system(env, path)
      raise "after-insert shell hook failed: #{path}" unless ok
    end

    class Context
      attr_reader :cli_options, :collected

      def initialize(cli_options)
        @cli_options = cli_options
        @collected = []
      end

      # ERB 評価。MongoDB 向けに `insert_jsonl` の別名も提供する (出力ファイル名・拡張子は
      # Runner 側で adapter.output_extension を元に決まるので、どちらを呼んでも同じバッファに溜まる)。
      def insert_sql(template)
        @collected << ERB.new(template, trim_mode: '-').result(binding)
      end
      alias_method :insert_jsonl, :insert_sql
    end
  end
end
```

ポイント:
- `instance_eval(File.read(path), path)` で、フックファイル内では `cli_options` と `insert_sql` が単純なメソッド呼び出しとして使える (DSL 風)。
- ERB 評価は `Context#insert_sql` の `binding` を使うため、ERB テンプレート内でも `cli_options.fetch(:ids)` が呼べる。
- `insert_sql` / `insert_jsonl` を複数回呼ぶと `@collected` に積まれ、最後に `"\n"` で連結して 1 ファイルに書く。
- 空出力なら書き出さない (idempotency に近い挙動)。
- shell 実行は `system(env, path)`。`path` は単独引数として渡すのでシェル展開されない (Shellwords 必要なし)。失敗時は exception で停止 → exit。
- ENV 名は `EXWIW_*` 接頭辞で名前空間を切る。`DATABASE_PASSWORD` は親プロセスの ENV を継承させる (フック側で読みたければ読める)。

### lib/exwiw.rb への require 追加
`require_relative "exwiw/after_insert_hook"` を `runner.rb` の require の前後あたりに追加。

### 使用例 (README に追記)

`hooks/seed_default_users.rb`:
```ruby
# cli_options[:ids] には --ids で渡された配列が入る
insert_sql <<~SQL
  -- seed default users for tenants <%= cli_options.fetch(:ids).join(',') %>
  <%- cli_options.fetch(:ids).each do |tenant_id| -%>
  INSERT INTO users (tenant_id, email) VALUES (<%= tenant_id %>, 'default@example.com');
  <%- end -%>
SQL
```

実行:
```
exwiw --adapter=mysql2 ... --target-table=shops --ids=1,2 \
  --after-insert=hooks/seed_default_users.rb
```
結果: `dump/insert-{total+1}-after_insert.sql` が、テナント 1,2 用の INSERT を含めて出力される。

## Files to modify / add

| パス | 変更 |
|---|---|
| `lib/exwiw/cli.rb` | `--after-insert` parse / validate / `build_cli_options_hash` 追加、Runner 呼び出しへ伝搬 |
| `lib/exwiw/runner.rb` | `initialize` に `after_insert_path:`, `cli_options:` 追加、per-table ループ完了後にフック呼び出し |
| `lib/exwiw/after_insert_hook.rb` (新規) | `AfterInsertHook.run` + `Context` (DSL + ERB) |
| `lib/exwiw.rb` | `require_relative "exwiw/after_insert_hook"` 追加 |
| `README.md` | `--after-insert` の節を追加 (Ruby DSL 例 / shell hook 例 / 環境変数一覧) |
| `spec/runner_spec.rb` | Ruby フックで `insert-{N+1}-after_insert.sql` が書き出され、ERB で `cli_options.fetch(:ids)` が展開されることを assert |
| `spec/after_insert_hook_spec.rb` (新規) | `Context#insert_sql` の ERB 評価、複数回呼び出しが `"\n"` 連結されることを assert |

## Verification

1. **ユニットテスト**: `bundle exec rspec spec/after_insert_hook_spec.rb` — `Context#insert_sql` を直接叩いて、ERB が `cli_options.fetch(:ids)` を解決できること、複数回呼び出しが `\n` 連結されることを確認。
2. **統合テスト**: `bundle exec rspec spec/runner_spec.rb` — sqlite3 経由で実際に Runner を流し、tmp に書いたフック `.rb` を `--after-insert` 相当で渡し、`tmp/.../insert-{N+1}-after_insert.sql` が生成されることと、ファイル内に ERB 展開後の `--ids` の値が含まれることを assert。
3. **CLI E2E**: scenario の `test_with_sqlite3.sh` を一時的に編集して `--after-insert=` を付けた呼び出しを試し、出力ディレクトリに想定どおりのファイルが置かれることを目視確認。MongoDB は `--after-insert=hook.rb` で `insert_jsonl` を使ったときに `.jsonl` が出ることのみ smoke-test。
4. **エッジケース確認**:
   - `--after-insert=missing.rb` でわかりやすいエラー終了。
   - フック内で `insert_sql` を 1 度も呼ばなかったとき、ファイルは作られず info ログのみ。
   - shell hook の non-zero exit code で Runner が落ちる。
   - `--ids` 省略時に `cli_options.fetch(:ids)` が空配列を返す (`@ids = []` 初期値が保たれる)。

## 留意点 / 既知のリスク

- **任意コード実行**: `.rb` フックは `instance_eval` で実行される (= exwiw プロセスと同じ権限で動く)。ユーザ自身が用意した hook を渡す前提なので問題ないが、README に「信頼するソースのみ」と注意書きを入れる。
- **ファイル番号の衝突**: `delete-*` は逆順番号 (`total_size - idx`) を使うので、`insert-{total+1}-after_insert` と直接衝突はしない (`delete-001`...`delete-{total}` の範囲)。
- **MongoDB 対応の限界**: `insert_jsonl` は ERB 出力結果を `.jsonl` としてそのまま書き出す。1 行 1 ドキュメントの形に揃えるのはユーザ責任。`mongoimport` で流せる前提。
- **password の取り扱い**: shell hook の env に `DATABASE_PASSWORD` を明示的に詰めない (親プロセス ENV を継承させる)。プロセス一覧経由の漏えいを防ぐため、ENV を介すのは hash で `EXWIW_*` のみ。
