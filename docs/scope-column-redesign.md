# scope-column まわりの再設計メモ（2026-06-23）

> ステータス: **(a) で決定**。hybrid は畳む（PR #128 の hybrid 中核を revert し、per-table scope-column モードに作り直す）。確定仕様は末尾「決定: (a) の確定仕様」を参照。

## 背景 / 解きたい問題

Rails の multi-database（`connects_to`）で、別 DB のモデルを指す `belongs_to`（cross-database）は **join できない**。

```ruby
# main DB
class Customer < ApplicationRecord
  belongs_to :tenant, class_name: "Org::Tenant"   # tenants は別 DB
end
# org DB
class Org::Tenant < OrgApplicationRecord
end
```

`customers.tenant_id` は join では絞れないが、**列の値（tenant_id）で直接フィルタ**はできる。これを使ってテナント単位 / 対象単位でデータ抽出したい。

## いまある実装（PR #128, draft / branch `feat/hybrid-target-scope-column`）

- **hybrid モード**: `--target-table` と `--scope-column` を併用。各テーブルを「target 到達」OR「scope 列到達」の**和集合（OR）**で解決。scope 値は target から**導出**する
  （`scope_column IN (SELECT target.scope_column FROM target WHERE <target ids>)`）。SQL only / insert-only / 単一アンカーは従来と byte 同一。
- **generator**: cross-database `belongs_to` を検出し、**relation だけ** `ignore: true` + `ignore_type: "cross_database"`（テーブル本体・FK 列は維持）。生成時にサマリ出力。
- **R2**: per-table `scope_column` があるのに `--scope-column` 未指定ならエラー。

## 再設計の方針（この議論での決定）

1. **per-table `scope_column` を唯一の宣言にする。** scoped なテーブルは config に `scope_column: <列>` を明示。
   グローバル `--scope-column`（正準名）＋ per-table オーバーライド、という二層と「オーバーライド」概念は**廃止**。
   各テーブルが自分の列を宣言する（差異名も自然に表現できる。全 scope 列は同じ値空間を持つ前提）。
2. **`--scope-column` フラグは deprecated**（警告を出して per-table 宣言へ誘導）。
3. **`--ids-column` は削除**。「自然キー（email 等）で target を指定する」ユースケースが無いため。
   scoped な target では `scope_column` が「`--ids` を当てる列」を兼ねる。
4. **generator の誘導文を更新**: 「越境は `--scope-column` を使え」→「**このテーブルに `scope_column:` を宣言しろ**」。
   検出・relation ignore・FK 列維持・サマリ自体は据え置き。
5. **R2 は撤回**（グローバルフラグ概念が無くなるため、per-table 宣言が正道になる）。

ここまでは hybrid の有無に関わらず確定。

## 未解決: hybrid は要るのか？

抽出ニーズが2種類あり、片方は pure scope-column モードでは実現できない。

### (a) テナント丸ごと抽出 — pure scope で足りる
「tenant 42 のデータを全部」。各 scoped テーブルを自分の `scope_column IN (42)` で絞るだけ。未 scoped テーブルは belongs_to 経由（via_path / referenced_by）。→ **hybrid 不要**。

### (b) 対象を絞った最小抽出 + cross-DB 行 — hybrid が必要
「shop 1 のデータだけ最小で欲しい。ただし join できない cross-DB の `customers`（shop 1 のテナントに属する）も含めたい」。

- pure scope（テナント単位）だと **tenant 42 全体**を引いてしまい多すぎる（shop 1 以外の shop も customers も入る）。
- 素の `--target-table=shops`（join 抽出）だと、cross-DB の `customers` には**到達できない**（join 不可）。
- → **shop 1 を主キーで anchor しつつ、その tenant_id を導出して cross-DB テーブルを scope する hybrid でしか実現できない**。

テスト用データ抽出は (b)（最小・対象限定）になりがちなので、hybrid は捨てがたい。

### CLI 上の衝突（ここが論点）

`--ids-column` を消したので、**scoped な target の `--ids` を 2 通りに解釈できない**:

- 解釈A: `--target-table=shops --ids=42` の 42 = `scope_column` の値（テナント抽出）
- 解釈B: `--target-table=shops --ids=1` の 1 = 主キー（hybrid: shop 1 を anchor して導出）

同じ CLI 形では両立しない。→ どちらかを選ぶ:

- **解釈A を採る**なら hybrid は畳む（pure scope-column モードに作り直す）。(b) は失われる。
- **hybrid を残す**なら scoped target の `--ids` は**主キー**（解釈B）に戻し、テナント抽出（a）は **target 無しの pure scope**（または deprecated な `--scope-column`）で行う。

### 推奨（たたき台）

**hybrid を残す**案。理由: 元々の動機（cross-DB FK を含めて1回で対象を抽出）と (b) のニーズが一致し、すでに #128 で動いている。
per-table `scope_column` 化とも両立できる ―― hybrid の導出元 scope 列を「`--scope-column` フラグ」ではなく **target の config の `scope_column`** から取れば、フラグ無し・`--ids-column` 無しで成立する:

| やりたいこと | コマンド | ids の意味 | 挙動 |
|---|---|---|---|
| shop 1 を最小抽出（cross-DB 含む） | `--target-table=shops --ids=1` | 主キー | shop 1 + 到達分。cross-DB/scoped テーブルは shops.`scope_column` から導出した tenant に scope（hybrid） |
| tenant 42 を丸ごと | `--ids=42`（target 無し） | scope 値 | 各 scoped テーブルを自分の `scope_column IN (42)`（pure scope） |
| 通常の単体抽出（scope 無し） | `--target-table=orders --ids=1`（orders に scope_column 無し） | 主キー | 従来どおり |

この案だと「解釈A（scoped target で ids=scope 値）」は捨て、テナント抽出は no-target の pure scope に寄せることになる。

## 決定: (a) の確定仕様

(a) のみ採用。hybrid（(b)）は今回入れない。

### モデル
- scoped なテーブルは config に `scope_column: <列>` を宣言（per-table のみ。グローバル正準名もオーバーライドも無し。全 scope 列は同じ値空間）。

### 起動と挙動
| コマンド | 条件 | ids の意味 | 挙動 |
|---|---|---|---|
| `--target-table=shops --ids=42` | shops が `scope_column` を宣言 | **scope 値** | scope-column モード。`scope_column` を宣言する全テーブルが自分の `scope_column IN (42)`。未宣言テーブルは belongs_to 経由（via_path / referenced_by）。`scope_exempt` は full dump。解決不能は abort（validate_scope!）。target 名は PK フィルタには使わない（scoped テーブルの1つとして scope される） |
| `--target-table=orders --ids=1` | orders は `scope_column` 無し | 主キー | 従来の単体 target 抽出（変更なし） |
| `--scope-column=C --ids=42` | deprecated | scope 値 | 旧 pure scope（no target、global 列 C）。**警告**を出す。`--target-table` とは排他（pre-#128 に戻す） |
| `--ids=42` のみ | target も flag も無し | — | エラー（従来どおり） |

- `--ids-column` は**削除**。scoped target では `scope_column` が「`--ids` を当てる列」を兼ねる。
- scoped なテーブルを主キーで単体抽出することはできなくなる（解釈A の代償。受容済み）。

### 実装スコープ（PR #128 を作り直す）
1. builder: #128 の hybrid 一式（build_hybrid / compose_or / pk_in_subquery / mode 引数 / 導出版 scope_where_clause / validate_hybrid! / R2=validate_scope_column_usage!）と `:or`（query_ast + 3 adapter）を **revert**。`scope_where_clause` はリテラル `scope_column IN (ids)` に戻す。
2. builder: `scope_mode?` を「`--scope-column` フラグ or **target が `scope_column` を宣言**」で判定するよう拡張。`resolved_scope_column = table.scope_column || （deprecated flag）`。
3. CLI: `--ids-column` 削除、`--scope-column` を deprecated 警告化 + `--target-table` と排他（pre-#128 に戻す）、hybrid 用の `--insert-only` 必須を撤去。
4. runner/explain: `validate_hybrid!` / `validate_scope_column_usage!` 呼び出しを撤去。`validate_scope!` の起動条件を新 `scope_mode?` に合わせる。
5. generator: cross-DB 検出は維持。comment / サマリの誘導を「`--scope-column` を使え」→「このテーブルに `scope_column:` を宣言しろ」に更新。
6. docs / CHANGELOG: hybrid 記述を撤去し、本モデルで書き直す。breaking（`--ids-column` 削除・`--scope-column` deprecated・scoped target の `--ids` 意味変更）を明記。tests も差し替え。
