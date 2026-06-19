# frozen_string_literal: true

require "spec_helper"
require "bson"

# Byte-identity guard for the native Relaxed Extended JSON encoder. DB-free: it
# synthesizes the Ruby shapes the Mongo driver hands back (Hash + BSON::ObjectId
# + Time + ...) and asserts the native C path emits the exact same bytes as the
# pure-Ruby `encode_fragment` for every representative shape.
#
# When the extension is not compiled (JRuby/TruffleRuby, or a build that failed)
# the native half is skipped with a clear message so the suite still passes on a
# fallback-only host; the fallback's own correctness is covered by the existing
# mongodb adapter / snapshot specs.
module Exwiw
  RSpec.describe ExtJson do
    native = ExtJson.respond_to?(:encode_native)

    # Each shape is checked two ways: the native bytes must equal the pure-Ruby
    # fragment bytes (the byte-identity contract), and the fragment must in turn
    # equal today's `JSON.generate(doc.as_extended_json(mode: :relaxed))` so the
    # fallback itself cannot silently drift.
    def expect_identical(value, native:)
      fragment = ExtJson.encode_fragment(value)
      reference = JSON.generate(value.respond_to?(:as_extended_json) ? value.as_extended_json(mode: :relaxed) : value)
      expect(fragment).to eq(reference)

      if native
        actual = ExtJson.encode_native(value)
        expect(actual).to eq(fragment)
        expect(actual.encoding).to eq(Encoding::UTF_8)
      end
    end

    oid = BSON::ObjectId.from_string("a00100000000000000000001")

    cases = {
      "nil" => nil,
      "true" => true,
      "false" => false,
      "empty hash" => {},
      "empty array" => [],
      "empty string" => "",
      "objectid" => oid,
      "objectid as _id" => { "_id" => oid },
      "plain string" => "hello world",
      "string with quote" => %(a"b),
      "string with backslash" => "a\\b",
      "string with slash (left raw)" => "a/b",
      "string short escapes" => "\b\t\n\f\r",
      "string control chars" => "\x01\x1f",
      "string NUL" => "\x00",
      "string DEL (raw)" => "\x7f",
      "string U+2028/U+2029 (raw)" => "  ",
      "string non-ascii (raw)" => "café 日本語",
      "string emoji" => "😀",
      "fixnum zero" => 0,
      "fixnum positive" => 42,
      "fixnum negative" => -1,
      "integer 9e9" => 9_000_000_000,
      "int64 max (bignum, in range)" => 2**63 - 1,
      "int64 min" => -(2**63),
      "float whole" => 100.0,
      "float one" => 1.0,
      "float negative zero" => -0.0,
      "float sci notation" => 1e20,
      "float small" => 1.5e-10,
      "float pi" => 3.14,
      "time sub-second" => Time.utc(2021, 1, 2, 3, 4, 5, 678_000),
      "time whole second" => Time.utc(2021, 1, 2, 3, 4, 5, 0),
      "time epoch" => Time.utc(1970, 1, 1, 0, 0, 0, 0),
      "time year 9999" => Time.utc(9999, 12, 31, 23, 59, 59, 500_000),
      "time last ISO second" => Time.at(253_402_300_799, 999_000_000, :nsec).utc,
      "time before 1970 (numberLong)" => Time.utc(1969, 12, 31, 23, 59, 59, 0),
      "time after 9999 (numberLong)" => Time.utc(10_000, 1, 1, 0, 0, 0, 0),
      # Sub-millisecond edges: usec != 0 forces a .mmm fraction, but the
      # millisecond is floor(nsec/1e6) — so 1..999 usec render as .000Z, while a
      # sub-microsecond (nsec < 1000) renders with no fraction at all.
      "time usec=1 floors to .000Z" => Time.at(5, 1, :usec).utc,
      "time usec=999 floors to .000Z" => Time.at(5, 999, :usec).utc,
      "time sub-microsecond (no fraction)" => Time.at(5, 500, :nsec).utc,
      "time nanosecond precision floors to ms" => Time.at(1_609_556_645, 678_999_999, :nsec).utc,
      "time non-UTC instant" => Time.new(2021, 1, 2, 3, 4, 5.678, "+09:00"),
      "symbol value (delegated)" => :hello,
      "symbol hash key" => { name: "x" },
      "integer hash key" => { 3 => "x" },
      "nested hash and array" => { "x" => [1, { "y" => 2 }, "z"] },
      "embed-heavy document" => {
        "_id" => oid,
        "name" => "User 1",
        "email" => "user1@example.com",
        "shop_id" => BSON::ObjectId.new,
        "created_at" => Time.utc(2025, 1, 1, 0, 0, 0, 0),
        "score" => 3.14,
        "active" => true,
        "deleted_at" => nil,
        "posts" => [
          { "_id" => BSON::ObjectId.new, "title" => "First", "likes" => 7, "at" => Time.utc(2025, 6, 1, 12, 30, 0, 123_000) },
          { "_id" => BSON::ObjectId.new, "title" => "Second \"quoted\" / line\nbreak", "likes" => 0 },
        ],
      },
    }

    cases.each do |name, value|
      it "encodes #{name} byte-identically" do
        expect_identical(value, native: native)
      end
    end

    describe "out-of-int64 Integer" do
      [2**63, -(2**63) - 1, 2**100].each do |big|
        it "raises the same RangeError as the pure-Ruby path for #{big}" do
          expect { ExtJson.encode_fragment(big) }
            .to raise_error(RangeError, /too big to be represented as a MongoDB integer/)

          if native
            expect { ExtJson.encode_native(big) }
              .to raise_error(RangeError, /too big to be represented as a MongoDB integer/)
          end
        end
      end
    end

    describe ".encode" do
      it "produces the same bytes as the pure-Ruby fragment for a document" do
        doc = { "_id" => oid, "name" => "x", "n" => 1, "t" => Time.utc(2025, 1, 1) }
        expect(ExtJson.encode(doc)).to eq(ExtJson.encode_fragment(doc))
      end
    end

    it "exercises the native path in this run" do
      skip "native extension not compiled; run `rake compile` to exercise it" unless native
      expect(native).to be(true)
    end
  end
end
