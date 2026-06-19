# Plan: Back out MongoDB fork/cursor parallelism → optional Extended-JSON C extension

## Context (why)

This branch (`gnhf/rt-rails-mongodb-dum-ed518c`) shipped a large MongoDB-dump perf effort across 18 iterations. The memory wins (iter 2–5: streaming result set + chunked output + precompiled `MaskPlan`) are clean, byte-identical, no-flag defaults and stay. But the CPU/throughput half (iter 6–18) grew into heavy multi-process machinery: two CLI flags (`--parallel-workers`, `--cursor-parallel`), four components (`ParallelSerializer`, `MongoIdPartitioner`, `PropagationCapture`, `ForkedPartWriter`), adapter `write_bulk_insert`/`write_inserts` seams, CLI→Runner→Adapter threading, fork orchestration, Marshal IPC, `_id`-range partitioning, distributed `@state` merge, and a sorted-output caveat — to buy ~1.1–1.4× (serialize-fork) / ~2.5–5.5× (cursor-parallel).

The maintainer's decision: **this is over-engineered.** Preserve the findings as `docs/optimization-notes.md`, **remove the parallelism**, and address the CPU hotspot with a much simpler lever the earlier iterations kept pointing at — a **C extension** for the dominant `as_extended_json(mode: :relaxed) + JSON.generate` cost.

**Honest scope of the win:** a C extension speeds only the per-document Extended-JSON *serialization* (~82% of per-doc serialize cost). It cannot touch the Mongo cursor's BSON→Ruby *decode* (~40% of total wall time, inside the driver) — that was cursor-parallel's job and is being removed. So end-to-end is bounded ~2.5× (the same Amdahl ceiling `--parallel-workers` hit), not cursor-parallel's 3.4–5.5×. The trade is deliberate: far simpler code + a no-flag, no-fork, single-process CPU win, for a smaller peak speedup. Memory behavior is unchanged (streaming stays the default).

## Part 1 — Remove the fork/cursor parallelism (keep streaming + MaskPlan)

Verified: `git diff b389204..HEAD` on the core lib files is **entirely** parallelism (`b389204` = iter-5 "MaskPlan" commit). So the iter-5 versions are exactly the "keep streaming, drop parallel" baseline.

**Restore to `b389204` (clean streaming baseline):**
- `lib/exwiw/runner.rb` — back to the inline `each_slice` chunk loop (`file.print(adapter.to_bulk_insert(chunk))`), no `write_inserts`/`parallel_workers`/`cursor_parallel`.
- `lib/exwiw/adapter.rb` — `Base#initialize(connection_config, logger)` (drop the two kwargs + ivars), `self.build(connection_config, logger)`; drop the `write_bulk_insert`/`write_inserts` seams (they exist only for parallelism). Keep `default_bulk_insert_chunk_size` (streaming).
- `lib/exwiw/adapter/mongodb_adapter.rb` — iter-5 form: `StreamingResult` without `query`/`keys` readers; `db` with inline client construction (drop `build_client`); no `write_bulk_insert`/`write_inserts`/`cursor_parallel`/`parallel_workers`/partitioner/capture. Keep `StreamingResult`, `MaskPlan`, chunking. (Then patch `serialize_document` in Part 3.)
- `lib/exwiw/cli.rb` — drop `--parallel-workers`/`--cursor-parallel` flags, ivars, `validate_parallel_workers!`/`validate_cursor_parallel!`, and the Runner kwargs.
- `lib/exwiw.rb` — drop the four parallel `require_relative` lines (Part 3 adds the `ext_json` require).

**Delete (components + specs + probes):**
- `lib/exwiw/{parallel_serializer,forked_part_writer,mongo_id_partitioner,propagation_capture}.rb`
- `spec/{parallel_serializer,forked_part_writer,mongo_id_partitioner,propagation_capture}_spec.rb`
- `script/bench_mongodb_parallel_probe.rb`, `script/bench_mongodb_cursor_parallel_probe.rb`

**Restore to `b389204`:** `spec/adapter_spec.rb`, `spec/cli_spec.rb`, `spec/adapter/mongodb_adapter_spec.rb`, `script/bench_mongodb_dump.rb` (all post-iter-5 changes there are parallel-only).

**Edit, don't restore:** `README.md`, `CHANGELOG.md` — remove the `--parallel-workers` / `--cursor-parallel` / `EXWIW_MONGODB_*` sections; the `[Unreleased]` entry becomes "streaming/chunked MongoDB dump by default + optional Extended-JSON C extension", pointing to `docs/optimization-notes.md`.

## Part 2 — `docs/optimization-notes.md`

Distill the 18-iteration log (`.gnhf/runs/.../notes.md`) into a durable doc: the two hotspots (result-set memory; `as_extended_json` CPU), what shipped by default (streaming + chunking + `MaskPlan`), and the **explored-and-removed** parallelism — fork serialize (~1.1–1.4×), cursor-parallel (~3.4–5.5× but heavy: IPC, `_id` partitioning, distributed `@state`, sorted output) — with the Amdahl reasoning (serial cursor decode floor) and *why* it was removed in favor of the C extension. This is the knowledge-preservation the maintainer asked for.

## Part 3 — Optional Extended-JSON C extension — DOCUMENT ONLY (not implemented now)

**Revised scope (per maintainer):** Part 3 is NOT implemented in this pass. Instead, write the design below into `docs/optimize-mongodb-export-with-native-ext.md` as a future-work / design doc. Only Part 1 and Part 2 are executed now.

Design to capture: replaces `JSON.generate(doc.as_extended_json(mode: :relaxed))` with one native tree-walk that emits the Relaxed Extended JSON line directly — no intermediate transformed-Hash tree, no second JSON pass.

**New files**
- `ext/exwiw/ext_json/extconf.rb` — `mkmf` (stdlib), `create_makefile("exwiw/ext_json_native")`.
- `ext/exwiw/ext_json/ext_json.c` — defines `Exwiw::ExtJson.encode_native(doc) -> String` (one JSONL line, no trailing `\n`). Recursive emitter into a growth buffer.
- `lib/exwiw/ext_json.rb` — shim: `require "exwiw/ext_json_native"` (distinct name avoids self-collision); on `LoadError`, define a pure-Ruby `encode`. Exposes one stable `Exwiw::ExtJson.encode(doc)`. Fallback is **byte-for-byte today's code**:
  ```ruby
  JSON.generate(doc.respond_to?(:as_extended_json) ? doc.as_extended_json(mode: :relaxed) : doc)
  ```

**Native fast-path vs delegate (byte-identity strategy, from the Plan agent's findings)**
- Native in C: `Hash` (insertion order via `rb_hash_foreach`; String keys), `Array`, `String` (escape only `\b\t\n\f\r\"\\`; lowercase `\u00xx` for other <0x20; leave `/`, DEL, U+2028/9, non-ASCII raw), `Integer` within int64, `true`/`false`/`nil`, and `BSON::ObjectId` → `{"$oid":"<24 hex>"}` (hex via `to_s`).
- **Delegate to Ruby** (call back to a fallback helper returning the JSON fragment for that value): `Float` (`Float#to_s` ≠ `JSON.generate` for sci-notation, e.g. `1e20`), `Time` (variable fractional digits + the years-[1970,9999] `$numberLong` boundary — highest risk), out-of-int64 `Integer` (must preserve the existing `RangeError`), and any unrecognized class (Decimal128, Binary, Symbol, Regexp, Date, …). This is provably byte-identical because `Hash/Array#as_extended_json` are non-transforming structural recursion, so `JSON.generate(v.as_extended_json(mode: :relaxed))` on any sub-value matches the whole-tree output. Time/Float are candidates for later native promotion if the benchmark justifies the added risk.

**Packaging / wiring**
- `exwiw.gemspec` — `spec.extensions = ["ext/exwiw/ext_json/extconf.rb"]` (auto-compiles on `gem install`; fallback covers platforms that can't).
- `Rakefile` — `Rake::ExtensionTask.new("ext_json_native")`; make `spec` depend on `compile`.
- Add `rake-compiler` as a dev dep (Gemfile/gemspec). `mkmf` is stdlib.
- `.gitignore` — ignore built artifacts (`lib/exwiw/*.bundle`, `lib/exwiw/*.so`, `ext/**/*.o`, `ext/**/Makefile`); commit only `ext/` sources (gemspec ships via `git ls-files`).
- `lib/exwiw.rb` — `require_relative "exwiw/ext_json"`.
- `lib/exwiw/adapter/mongodb_adapter.rb` — `serialize_document`/`to_bulk_insert` inner call becomes `ExtJson.encode(doc)` (after `apply_mask_plan!`); remove the now-unused private `#extended_json`.

## Verification (Part 1 + Part 2 scope)

- **`bundle exec rspec`** — full suite green after the revert. The parallel specs are deleted; the restored specs match iter-5. (`spec/insert_output_snapshot_spec.rb` and other mongodb-touching specs need live mongo on 27017 → sandbox disabled; the rest run normally.)
- **`spec/insert_output_snapshot_spec.rb`** (mongodb fixtures, live mongo) — the byte-exact guard; output bytes must be unchanged by the revert (streaming default is byte-identical to iter-5).
- `git grep -nE 'parallel_workers|cursor_parallel|ParallelSerializer|MongoIdPartitioner|PropagationCapture|ForkedPartWriter'` returns nothing in `lib/`, `spec/`, `exe/`, `README.md` after the revert (confirms full removal).
- `docs/optimize-mongodb-export-with-native-ext.md` and `docs/optimization-notes.md` exist and read coherently.

## Notes
- No `git rebase`/`push -f` (history may stay messy; backing out via forward edits + deletions, not history rewrite).
- After implementation, offer to commit the plan via the remember-plan skill.
