// Native emitter for MongoDB Relaxed Extended JSON.
//
// Replaces the pure-Ruby `JSON.generate(doc.as_extended_json(mode: :relaxed))`
// (which rebuilds the whole document into an intermediate transformed Hash tree
// and then walks it a second time in JSON.generate) with a single native
// tree-walk that emits the JSONL line directly.
//
// Byte-identity strategy (see docs/optimize-mongodb-export-with-native-ext.md):
// only the structural bulk + the cheapest, most-stable leaves are formatted in
// C — Hash, Array, String, fixnum Integer, true/false/nil, BSON::ObjectId, and
// in-range Time (years 1970..9999; see encode_time_native). Everything else
// (Float, out-of-int64 Integer, out-of-range Time, Symbol, Decimal128, Binary,
// ...) is handed back to Ruby's `encode_fragment`, which is the exact pure-Ruby
// path. This is provably byte-identical because Hash#as_extended_json
// and Array#as_extended_json are non-transforming structural recursion: the
// bytes `JSON.generate(v.as_extended_json(mode: :relaxed))` produces for any
// sub-value `v` are exactly the bytes the whole-document generate would produce
// in that position, so a value the native walk does not format can be spliced
// in verbatim with no divergence.

#include <ruby.h>
#include <ruby/encoding.h>
#include <stdio.h>
#include <time.h>

static VALUE rb_mExtJson;
// Cached BSON::ObjectId class, or Qnil until bson is loaded and it resolves.
// Resolution is lazy (bson is required only when the Mongo adapter touches the
// DB, which always precedes serialization in a real run); see resolve below.
static VALUE rb_cObjectId;

static ID id_encode_fragment;
static ID id_to_s;
static ID id_const_BSON;
static ID id_const_ObjectId;

static const char hexdigits[] = "0123456789abcdef";

static void encode_value(VALUE buf, VALUE val);

// Append `str` as a JSON string literal (surrounding quotes included), escaping
// exactly as JSON.generate does: \b \t \n \f \r \" \\ get their short escapes,
// any other byte < 0x20 becomes a lowercase \u00xx, and every other byte —
// including '/', DEL (0x7f), U+2028/U+2029, and UTF-8 multi-byte sequences — is
// passed through raw. Unescaped runs are appended in bulk to avoid a per-byte
// rb_str_cat call.
static void encode_string(VALUE buf, const char *p, long len)
{
    rb_str_cat(buf, "\"", 1);

    long start = 0;
    for (long i = 0; i < len; i++) {
        unsigned char c = (unsigned char)p[i];
        const char *esc = NULL;
        long esclen = 0;
        char ubuf[6];

        switch (c) {
            case '"':  esc = "\\\""; esclen = 2; break;
            case '\\': esc = "\\\\"; esclen = 2; break;
            case '\b': esc = "\\b";  esclen = 2; break;
            case '\t': esc = "\\t";  esclen = 2; break;
            case '\n': esc = "\\n";  esclen = 2; break;
            case '\f': esc = "\\f";  esclen = 2; break;
            case '\r': esc = "\\r";  esclen = 2; break;
            default:
                if (c < 0x20) {
                    ubuf[0] = '\\'; ubuf[1] = 'u'; ubuf[2] = '0'; ubuf[3] = '0';
                    ubuf[4] = hexdigits[(c >> 4) & 0xf];
                    ubuf[5] = hexdigits[c & 0xf];
                    esc = ubuf; esclen = 6;
                }
        }

        if (esc) {
            if (i > start) rb_str_cat(buf, p + start, i - start);
            rb_str_cat(buf, esc, esclen);
            start = i + 1;
        }
    }
    if (len > start) rb_str_cat(buf, p + start, len - start);

    rb_str_cat(buf, "\"", 1);
}

// Hash keys mirror JSON.generate: a String key is emitted as-is, anything else
// is stringified (Symbol via its name, otherwise #to_s) before escaping.
static void encode_key(VALUE buf, VALUE key)
{
    VALUE kstr;
    if (RB_TYPE_P(key, T_STRING)) {
        kstr = key;
    } else if (RB_TYPE_P(key, T_SYMBOL)) {
        kstr = rb_sym2str(key);
    } else {
        kstr = rb_funcall(key, id_to_s, 0);
    }
    encode_string(buf, RSTRING_PTR(kstr), RSTRING_LEN(kstr));
}

typedef struct {
    VALUE buf;
    int first;
} hash_ctx;

static int hash_iter(VALUE key, VALUE value, VALUE arg)
{
    hash_ctx *ctx = (hash_ctx *)arg;
    if (!ctx->first) rb_str_cat(ctx->buf, ",", 1);
    ctx->first = 0;
    encode_key(ctx->buf, key);
    rb_str_cat(ctx->buf, ":", 1);
    encode_value(ctx->buf, value);
    return ST_CONTINUE;
}

// Splice the pure-Ruby fragment for a value the native path does not format.
static void delegate(VALUE buf, VALUE val)
{
    VALUE frag = rb_funcall(rb_mExtJson, id_encode_fragment, 1, val);
    rb_str_cat(buf, RSTRING_PTR(frag), RSTRING_LEN(frag));
}

// Epoch second for 10000-01-01T00:00:00Z. `bson`'s relaxed Time encoding uses
// the ISO-8601 string form only for years 1970..9999 (inclusive) and the
// {"$numberLong":"<ms>"} form otherwise; that year window is exactly the
// half-open epoch-second range [0, MAX_ISO_EPOCH).
#define MAX_ISO_EPOCH 253402300800LL

// Format a Time as Relaxed Extended JSON in C, matching bson 5.2.0 byte for
// byte for the common in-range case (see bson/time.rb and the empirical probe):
//   - whole second (usec == 0, i.e. nsec < 1000): {"$date":"...:SSZ"} (no fraction)
//   - sub-second   (nsec >= 1000):                {"$date":"...:SS.mmmZ"}, where the
//     millisecond is floor(nsec / 1e6) — bson floors the Time to milliseconds.
// Returns 1 when handled. Returns 0 (leaving buf untouched) for years outside
// 1970..9999, whose {"$numberLong"} form involves negative-epoch arithmetic too
// fiddly to risk in C — the caller then delegates that rare case to Ruby.
static int encode_time_native(VALUE buf, VALUE val)
{
    struct timespec ts = rb_time_timespec(val);
    if (ts.tv_sec < 0 || ts.tv_sec >= MAX_ISO_EPOCH) return 0;

    time_t secs = (time_t)ts.tv_sec;
    struct tm tm;
    if (gmtime_r(&secs, &tm) == NULL) return 0;

    char tmp[40];
    int n;
    if (ts.tv_nsec >= 1000) {
        int ms = (int)(ts.tv_nsec / 1000000L);
        n = snprintf(tmp, sizeof(tmp),
                     "{\"$date\":\"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ\"}",
                     tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                     tm.tm_hour, tm.tm_min, tm.tm_sec, ms);
    } else {
        n = snprintf(tmp, sizeof(tmp),
                     "{\"$date\":\"%04d-%02d-%02dT%02d:%02d:%02dZ\"}",
                     tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                     tm.tm_hour, tm.tm_min, tm.tm_sec);
    }
    rb_str_cat(buf, tmp, n);
    return 1;
}

static void encode_value(VALUE buf, VALUE val)
{
    switch (TYPE(val)) {
        case T_NIL:
            rb_str_cat(buf, "null", 4);
            return;
        case T_TRUE:
            rb_str_cat(buf, "true", 4);
            return;
        case T_FALSE:
            rb_str_cat(buf, "false", 5);
            return;
        case T_FIXNUM: {
            // A Fixnum always fits in a C long (and thus int64) on the platforms
            // exwiw targets, so it can never be the out-of-int64 case that must
            // raise; emit it directly. Bignums fall through to delegate, where
            // encode_fragment emits in-range ones and raises RangeError for the
            // rest — matching today's behavior exactly.
            char tmp[24];
            int n = snprintf(tmp, sizeof(tmp), "%ld", (long)FIX2LONG(val));
            rb_str_cat(buf, tmp, n);
            return;
        }
        case T_STRING:
            encode_string(buf, RSTRING_PTR(val), RSTRING_LEN(val));
            return;
        case T_ARRAY: {
            long len = RARRAY_LEN(val);
            rb_str_cat(buf, "[", 1);
            for (long i = 0; i < len; i++) {
                if (i > 0) rb_str_cat(buf, ",", 1);
                encode_value(buf, rb_ary_entry(val, i));
            }
            rb_str_cat(buf, "]", 1);
            return;
        }
        case T_HASH: {
            // rb_hash_foreach preserves insertion order, matching JSON output.
            hash_ctx ctx = { buf, 1 };
            rb_str_cat(buf, "{", 1);
            rb_hash_foreach(val, hash_iter, (VALUE)&ctx);
            rb_str_cat(buf, "}", 1);
            return;
        }
        default:
            // BSON::ObjectId is the single most common leaf (`_id`) and its
            // Relaxed form is the stable {"$oid":"<24 hex>"}, so format it here.
            // The hex comes from #to_s (the same source as as_extended_json) and
            // is always [0-9a-f]{24}, so it needs no escaping.
            if (!NIL_P(rb_cObjectId) && RTEST(rb_obj_is_kind_of(val, rb_cObjectId))) {
                VALUE hex = rb_funcall(val, id_to_s, 0);
                rb_str_cat(buf, "{\"$oid\":\"", 9);
                rb_str_cat(buf, RSTRING_PTR(hex), RSTRING_LEN(hex));
                rb_str_cat(buf, "\"}", 2);
                return;
            }
            // Time is the other common leaf in dumped documents (Mongoid's
            // created_at/updated_at); format the in-range case natively. The
            // out-of-range $numberLong form returns 0 and falls through to Ruby.
            if (RTEST(rb_obj_is_kind_of(val, rb_cTime)) && encode_time_native(buf, val)) {
                return;
            }
            // Float, Bignum, Symbol, Decimal128, Binary, out-of-range Time, ... -> Ruby.
            delegate(buf, val);
            return;
    }
}

// Resolve and cache BSON::ObjectId the first time a document is encoded with
// bson loaded. Cheap const lookups guarded by the Qnil cache; once resolved it
// is skipped. Until resolved, ObjectId simply takes the (correct) delegate path.
static void resolve_objectid_class(void)
{
    if (!NIL_P(rb_cObjectId)) return;
    if (!rb_const_defined(rb_cObject, id_const_BSON)) return;

    VALUE bson = rb_const_get(rb_cObject, id_const_BSON);
    if (rb_const_defined(bson, id_const_ObjectId)) {
        rb_cObjectId = rb_const_get(bson, id_const_ObjectId);
    }
}

// Exwiw::ExtJson.encode_native(doc) -> String
// Returns one JSONL line (no trailing newline); the caller owns separators.
static VALUE rb_encode_native(VALUE self, VALUE doc)
{
    resolve_objectid_class();

    VALUE buf = rb_str_buf_new(256);
    rb_enc_associate(buf, rb_utf8_encoding());
    encode_value(buf, doc);
    return buf;
}

void Init_ext_json_native(void)
{
    id_encode_fragment = rb_intern("encode_fragment");
    id_to_s = rb_intern("to_s");
    id_const_BSON = rb_intern("BSON");
    id_const_ObjectId = rb_intern("ObjectId");

    VALUE mExwiw = rb_define_module("Exwiw");
    rb_mExtJson = rb_define_module_under(mExwiw, "ExtJson");
    rb_global_variable(&rb_mExtJson);

    rb_cObjectId = Qnil;
    rb_global_variable(&rb_cObjectId);

    rb_define_singleton_method(rb_mExtJson, "encode_native", rb_encode_native, 1);
}
