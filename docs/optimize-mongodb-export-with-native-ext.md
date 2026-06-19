# Design: optional native (C) extension for the MongoDB Extended-JSON encoder

Status: **implemented.** This document captured the design; it now describes the
shipped encoder. Source: `ext/exwiw/ext_json/ext_json.c` (native emitter) and
`lib/exwiw/ext_json.rb` (the optional-load shim + pure-Ruby fallback); the
byte-identity guard is `spec/ext_json_spec.rb`. It is the successor to the
fork/cursor parallelism that was removed (see
[`optimization-notes.md`](./optimization-notes.md)).

## Motivation

When the MongoDB adapter dumps embed-heavy documents, the dominant CPU cost is
turning each decoded Mongo document (a Ruby `Hash` containing `BSON::ObjectId` /
`Time` / nested `Hash`+`Array`) into one JSONL line of MongoDB **Relaxed
Extended JSON**. Today that is:

```ruby
# lib/exwiw/adapter/mongodb_adapter.rb
JSON.generate(doc.as_extended_json(mode: :relaxed))
```

`as_extended_json` (in the pure-Ruby `bson` gem) **recursively rebuilds the
whole document into a new intermediate Hash tree** (`ObjectId -> {"$oid"=>…}`,
`Time -> {"$date"=>…}`, every subdoc/array re-allocated), and then
`JSON.generate` walks that tree a *second* time. For a 30-embedded-post doc this
was measured at ~130µs/doc and is ~82% of per-document serialization cost.

Earlier experiments established the levers:

- Threads give **zero** speedup — `as_extended_json` is pure Ruby and holds the GVL.
- A pure-Ruby fused single-pass encoder is **slower** (per-leaf `.to_json` C-call
  overhead beats it; `JSON.generate` does the whole tree in one C pass).
- Multi-process parallelism worked but was judged over-engineered and removed.

The remaining lever is a **C extension**: one native walk that emits the
Extended-JSON text directly — no intermediate transformed-Hash tree, no second
JSON pass.

## Goals / non-goals

- **Goal:** a native encoder that is **byte-for-byte identical** to the current
  pure-Ruby path, behind an **optional** load with a pure-Ruby fallback so
  exwiw stays installable as a pure-Ruby gem (JRuby/TruffleRuby, or any host
  where compilation fails, keep working).
- **Non-goal:** speeding up the Mongo cursor's BSON→Ruby *decode*. That lives in
  the `mongo`/`bson` driver and is ~40% of total dump wall time. A serialization
  C extension is therefore bounded to roughly the same end-to-end ceiling
  (~2.5×) the removed `--parallel-workers` path had — it does **not** reach the
  removed cursor-parallel path's 3.4–5.5×. This is an accepted trade for a far
  simpler, flag-free, fork-free implementation.

## Exact serialization semantics to reproduce (verified against bson 5.2.0)

The byte-exact anchor is `spec/insert_output_snapshot_spec.rb` (committed
`spec/insert_output_snapshots/mongodb/*.jsonl` fixtures). The C encoder must
reproduce the following exactly. All rows below were verified empirically and,
for `Time`, against `bson-5.2.0/lib/bson/time.rb:72-89`.

| Ruby value | Relaxed Extended JSON output | Notes |
|---|---|---|
| `BSON::ObjectId` | `{"$oid":"<24 lowercase hex>"}` | hex via `ObjectId#to_s` |
| `Time` (year 1970..9999, sub-second) | `{"$date":"2021-01-02T03:04:05.678Z"}` | floor to ms, `strftime('%Y-%m-%dT%H:%M:%S.%LZ')` |
| `Time` (year 1970..9999, whole second) | `{"$date":"2021-01-02T03:04:05Z"}` | **no** fraction when `usec == 0` |
| `Time` (year <1970 or >9999) | `{"$date":{"$numberLong":"<ms>"}}` | `ms = sec*1000 + usec.divmod(1000).first` |
| `Integer` (fits int64) | bare `42` / `9000000000` | |
| `Integer` (outside int64) | **raises `RangeError`** | `"Integer … too big to be represented as a MongoDB integer"` |
| `Float` | `JSON.generate(float)` form | `1e20 → 1e+20` (**not** `Float#to_s`'s `1.0e+20`); `100.0 → 100.0`; `-0.0 → -0.0` |
| `String` | JSON string | escape only `\b \t \n \f \r \" \\`; other `<0x20` as lowercase `\u00xx`; `/`, DEL, U+2028/U+2029, non-ASCII left raw |
| `true` / `false` / `nil` | `true` / `false` / `null` | |
| `Hash` | `{…}` | **insertion order** preserved; keys are Strings (JSON-escaped) |
| `Array` | `[…]` | |

`bson/time.rb` boundary (the highest-risk piece), verified verbatim:

```ruby
def as_extended_json(**options)
  if options[:mode] == :relaxed && (1970..9999).include?(utc_time.year)
    if utc_time.usec != 0
      utc_time = utc_time.floor(3)            # floor to millisecond
      {'$date' => utc_time.strftime('%Y-%m-%dT%H:%M:%S.%LZ')}
    else
      {'$date' => utc_time.strftime('%Y-%m-%dT%H:%M:%SZ')}
    end
  else
    msec = utc_time.usec.divmod(1000).first
    {'$date' => {'$numberLong' => (sec * 1000 + msec).to_s}}
  end
end
```

## Fast-path vs delegate (the byte-identity strategy)

The encoder splits values into a **native fast path** and a **Ruby delegate**:

- **Native (in C):** `Hash`, `Array`, `String`, `Integer` within int64,
  `true`/`false`/`nil`, `BSON::ObjectId`, and **in-range `Time`** (years
  1970..9999). These are the structural bulk plus the two most common leaves in
  a dumped document — `_id` and the Mongoid `created_at`/`updated_at` timestamps.
  The in-range Time path resolves the absolute instant with `rb_time_timespec`
  (epoch seconds + nanoseconds, no `rb_funcall`), formats with `gmtime_r` +
  `snprintf`, and reproduces bson's rule exactly: a `.mmm` fraction iff
  `nsec >= 1000` (i.e. `usec != 0`), with the millisecond floored to
  `nsec / 1e6`. The in-range window is the half-open epoch-second range
  `[0, 253402300800)`.
- **Delegate to Ruby** — call back into
  `JSON.generate(value.as_extended_json(mode: :relaxed))` for the individual
  value and splice the returned fragment into the buffer:
  - `Float` — `Float#to_s` diverges from `JSON.generate` for scientific notation
    (`1e20`), so never reformat floats in C.
  - **out-of-range `Time`** (year < 1970 or > 9999) — its `$numberLong` form
    involves negative-epoch arithmetic, is vanishingly rare in dumped data, and
    is left to Ruby. The in-range ISO branch is handled natively (above).
  - out-of-int64 `Integer` — must surface the identical `RangeError`.
  - any unrecognized class — `Decimal128`, `BSON::Binary`, `Symbol`, `Regexp`,
    `Date`, `BSON::Timestamp`, etc.

**Why delegating is provably byte-identical:** `Hash#as_extended_json` and
`Array#as_extended_json` are *non-transforming structural recursion* — they map
over children and call `as_extended_json` on each. So the bytes produced for any
sub-value `v` by `JSON.generate(v.as_extended_json(mode: :relaxed))` are exactly
the bytes that the whole-document `JSON.generate(doc.as_extended_json(...))`
would have produced for that position. The native walk can therefore hand any
value it does not want to format to Ruby and splice the result, with no
divergence.

`Time` was promoted into the native path because the benchmark showed it was
decisive: with `Time` delegated, a 30-embedded-post timestamp-heavy document
(32 `Time` fields) sped up only ~1.03× — the per-`Time` `rb_funcall` +
`as_extended_json` Hash allocation + second `JSON.generate` pass erased the win.
Formatting in-range `Time` natively brings the same document to ~2.8× (the
serialization-step ceiling). `Float` remains delegated: matching
`JSON.generate`'s shortest-round-trip float formatting in C (not `Float#to_s`)
is not worth the risk for the few floats a typical document carries.

## C source & buffer design

- `Exwiw::ExtJson.encode_native(doc) -> String` — returns one JSONL line, **no**
  trailing `\n` (the caller/Runner owns separators).
- Recursive emitter writing into a single growing buffer (`rb_str_buf_new` +
  `rb_str_cat`/`rb_str_buf_cat`, or a `malloc` buffer finalized to an
  `rb_utf8_str_new`). Result string is UTF-8.
- Type dispatch via `TYPE()` for the immediates/`T_HASH`/`T_ARRAY`/`T_STRING`/
  `T_FLOAT`/`T_FIXNUM`/`T_BIGNUM`, and a cached `BSON::ObjectId` class reference
  (`rb_const_get`) compared with `rb_obj_is_kind_of` for ObjectId.
- `Hash`: `rb_hash_foreach` preserves insertion order; emit `key:value` pairs;
  keys are Strings run through the same string escaper.
- Delegate path: a cached `ID` for a Ruby helper (e.g.
  `Exwiw::ExtJson.encode_fragment(v)`), `rb_funcall`'d, returning the JSON
  fragment String to splice. The `RangeError` for oversized integers propagates
  naturally through the delegate.
- String escaper implemented in C to match the table above (no per-leaf Ruby
  call for the common String case).

## Packaging, optional load, fallback

- **gemspec:** `spec.extensions = ["ext/exwiw/ext_json/extconf.rb"]`. With
  `extensions` set, `gem install exwiw` compiles automatically; hosts that can't
  compile fall back at runtime (below).
- **`ext/exwiw/ext_json/extconf.rb`:** `require "mkmf"` (stdlib) +
  `create_makefile("exwiw/ext_json_native")`. The compiled lib is named
  `ext_json_native` (distinct from the `ext_json.rb` shim) to avoid a
  `require` self-collision.
- **`ext/exwiw/ext_json/ext_json.c`:** the emitter; defines
  `Exwiw::ExtJson.encode_native`.
- **`lib/exwiw/ext_json.rb`** (the shim, always loaded):

  ```ruby
  require "json"

  module Exwiw
    module ExtJson
      module_function

      # Pure-Ruby fragment encoder used by both the fallback and the native
      # delegate path. Byte-identical to today's behavior.
      def encode_fragment(value)
        JSON.generate(value.respond_to?(:as_extended_json) ? value.as_extended_json(mode: :relaxed) : value)
      end

      begin
        require "exwiw/ext_json_native"   # defines Exwiw::ExtJson.encode_native
        def encode(doc) = encode_native(doc)
      rescue LoadError
        def encode(doc) = encode_fragment(doc)   # exact current behavior
      end
    end
  end
  ```

- **`Rakefile`:** `require "rake/extensiontask"`;
  `Rake::ExtensionTask.new("ext_json_native") { |e| e.ext_dir = "ext/exwiw/ext_json" }`;
  make the `spec` task depend on `compile`.
- **Dev dependency:** add `rake-compiler` (Gemfile / gemspec dev deps). `mkmf`
  is stdlib, no runtime dep added.
- **`.gitignore`:** ignore built artifacts (`lib/exwiw/*.bundle`,
  `lib/exwiw/*.so`, `ext/**/*.o`, `ext/**/Makefile`). Commit only the `ext/`
  sources; the gemspec ships files via `git ls-files`.
- **`lib/exwiw.rb`:** add `require_relative "exwiw/ext_json"`.

## Integration point

In `lib/exwiw/adapter/mongodb_adapter.rb`, the per-document serialize step
becomes (masking still runs in Ruby first; only the encode changes):

```ruby
def to_bulk_insert(rows, config)
  plan = mask_plan(config)
  rows.map do |doc|
    apply_mask_plan!(doc, plan)
    Exwiw::ExtJson.encode(doc)   # was: JSON.generate(extended_json(doc))
  end.join("\n")
end
```

The private `#extended_json` helper is removed — its logic (including the
`respond_to?(:as_extended_json)` guard) moves into `ExtJson.encode_fragment`.

## Test & benchmark strategy

- **`spec/ext_json_spec.rb`** (DB-free; the primary byte-identity guard, runs in
  normal CI): assert `encode_native(doc) == encode_fragment(doc)` over a fuzz of
  representative shapes — ObjectId; nested hashes/arrays; `Time` across the year
  boundary, whole-second (no fraction), and sub-second; strings with control
  chars / quotes / backslashes / non-ASCII / U+2028; ints, bignums (assert the
  same `RangeError`), floats (`1e20`, `-0.0`, `100.0`); `nil`; empty
  hash/array/string. Skip the native half with a clear message when the lib
  isn't compiled, so the suite still passes on a fallback-only host.
- **`spec/insert_output_snapshot_spec.rb`** (live mongo on 27017): the byte-exact
  fixtures must stay green with the native encoder built.
- **Microbench** (extend `script/bench_mongodb_dump.rb`): native-encode vs
  Ruby-fallback throughput on DB-free synthesized embed-heavy docs, plus the live
  path on 20k×30, to quantify the real speedup.

## Risk register

1. **Time formatting** — variable fraction + ms flooring + `$numberLong`
   boundary. In-range years (1970..9999) are formatted natively via
   `rb_time_timespec` + `gmtime_r`; the rare out-of-range `$numberLong` form is
   delegated. Mitigated by a dense byte-identity fuzz over the whole in-range
   epoch span with mixed nanosecond precision, plus the boundary/sub-ms edges in
   `spec/ext_json_spec.rb`.
2. **Float formatting** — `Float#to_s` ≠ `JSON.generate`. Mitigated by delegating.
3. **String escaping** — must match JSON exactly. Implemented in C, fuzz-tested
   vs the Ruby fallback.
4. **Hash key order** — preserved via `rb_hash_foreach`.
5. **Oversized integers** — delegate so the same `RangeError` surfaces.
6. **Encoding** — emit UTF-8; pass non-ASCII bytes through unescaped (matches JSON).
7. **Build/portability** — optional load + pure-Ruby fallback keeps non-CRuby and
   no-compiler installs working.
