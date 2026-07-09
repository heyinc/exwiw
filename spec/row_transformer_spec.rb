require 'spec_helper'

module Exwiw
  RSpec.describe RowTransformer do
    def build_table(columns)
      TableConfig.from_symbol_keys(name: 'users', primary_key: 'id', columns: columns)
    end

    def build_transformer(columns)
      RowTransformer.build(build_table(columns))
    end

    describe '.build' do
      it 'returns nil when no column carries a ruby-side mode' do
        expect(build_transformer([{ name: 'id' }, { name: 'name', replace_with: 'masked' }])).to be_nil
      end

      it 'returns nil for a config without a columns list (e.g. MongodbCollectionConfig)' do
        fields_only = Struct.new(:fields).new([])
        expect(RowTransformer.build(fields_only)).to be_nil
      end

      it 'returns a transformer when a column has map' do
        expect(build_transformer([{ name: 'id' }, { name: 'name', map: 'proc { |r| "x" }' }])).to be_a(RowTransformer)
      end
    end

    describe 'map mode' do
      it 'replaces the column with the proc result, reading other columns via r[]' do
        transformer = build_transformer([
          { name: 'id' },
          { name: 'email', map: 'proc { |r| "user#{r["id"]}@masked.example" }' },
        ])
        expect(transformer.wrap([['1', 'a@example.com'], ['2', 'b@example.com']]).to_a).to eq([
          ['1', 'user1@masked.example'],
          ['2', 'user2@masked.example'],
        ])
      end

      it 'passes nil through to the proc (no automatic NULL preservation)' do
        transformer = build_transformer([
          { name: 'id' },
          { name: 'email', map: 'proc { |r| r["email"].nil? ? "was-null" : "had-value" }' },
        ])
        expect(transformer.wrap([['1', nil]]).to_a).to eq([['1', 'was-null']])
      end

      it 'computes replacements from pre-transform values regardless of column order' do
        transformer = build_transformer([
          { name: 'a', map: 'proc { |r| r["b"] }' },
          { name: 'b', map: 'proc { |r| r["a"] }' },
        ])
        expect(transformer.wrap([['1', '2']]).to_a).to eq([['2', '1']])
      end

      it 'raises with column context when the proc source fails to eval' do
        expect {
          build_transformer([{ name: 'id' }, { name: 'name', map: 'proc { |r| ' }])
        }.to raise_error(ArgumentError, /map for column 'users\.name' failed to eval/)
      end

      it 'raises when the source does not evaluate to a Proc' do
        expect {
          build_transformer([{ name: 'id' }, { name: 'name', map: '"a string"' }])
        }.to raise_error(ArgumentError, /must evaluate to a Proc, got String/)
      end

      it 'raises with column context when the proc raises mid-row' do
        transformer = build_transformer([{ name: 'id' }, { name: 'name', map: 'proc { |r| raise "boom" }' }])
        expect {
          transformer.wrap([['1', 'x']]).to_a
        }.to raise_error(RuntimeError, /map proc for column 'users\.name' raised: RuntimeError: boom/)
      end

      it 'raises a helpful error when the proc reads an unknown column' do
        transformer = build_transformer([{ name: 'id' }, { name: 'name', map: 'proc { |r| r["nope"] }' }])
        expect {
          transformer.wrap([['1', 'x']]).to_a
        }.to raise_error(RuntimeError, /unknown column 'nope'.*available: id, name/)
      end
    end

    describe 'fake data mode' do
      def name_transformer
        build_transformer([
          { name: 'id' },
          { name: 'name', replace_with_fake_data: { seed: 'users.id', type: 'human_name' } },
        ])
      end

      it 'maps the same seed value to the same fake value across independently built transformers' do
        # Fresh pools on the second build: this is the determinism contract
        # (same faker version + locale => same value), without pinning any
        # faker-generated literal.
        first = name_transformer.wrap([['1', 'Alice']]).to_a
        RowTransformer.instance_variable_set(:@fake_pools, nil)
        second = name_transformer.wrap([['1', 'Bob']]).to_a
        expect(second[0][1]).to eq(first[0][1])
      end

      it 'normalizes seed values with to_s (sqlite Integer 1 == pg/mysql "1")' do
        transformer = name_transformer
        from_string = transformer.wrap([['1', 'Alice']]).to_a
        from_integer = transformer.wrap([[1, 'Alice']]).to_a
        expect(from_integer[0][1]).to eq(from_string[0][1])
      end

      it 'preserves NULL in the target column' do
        expect(name_transformer.wrap([['1', nil]]).to_a).to eq([['1', nil]])
      end

      it 'hashes "" for a nil seed value, deterministically' do
        transformer = build_transformer([
          { name: 'id' },
          { name: 'ref' },
          { name: 'name', replace_with_fake_data: { seed: 'ref', type: 'human_name' } },
        ])
        rows = transformer.wrap([['1', nil, 'Alice'], ['2', nil, 'Bob']]).to_a
        expect(rows[0][2]).to eq(rows[1][2])
        expect(rows[0][2]).to be_a(String)
      end

      it 'composes a 16-hex uniqueness token for email, distinct per seed' do
        transformer = build_transformer([
          { name: 'id' },
          { name: 'email', replace_with_fake_data: { seed: 'id', type: 'email' } },
        ])
        rows = transformer.wrap([['1', 'a@example.com'], ['2', 'b@example.com']]).to_a
        expect(rows[0][1]).to match(/\A\S+\.[0-9a-f]{16}@example\.com\z/)
        expect(rows[1][1]).to match(/\A\S+\.[0-9a-f]{16}@example\.com\z/)
        expect(rows[0][1]).not_to eq(rows[1][1])
      end

      it 'builds the pool with the requested locale' do
        transformer = build_transformer([
          { name: 'id' },
          { name: 'name', replace_with_fake_data: { seed: 'id', type: 'human_name', locale: 'ja' } },
        ])
        value = transformer.wrap([['1', 'x']]).to_a[0][1]
        expect(value).to match(/[\p{Hiragana}\p{Katakana}\p{Han}]/)
      end

      it 'raises at build when the seed resolves to a column dropped by ignore:true' do
        table = build_table([
          { name: 'id' },
          { name: 'legacy', ignore: true },
          { name: 'name', replace_with_fake_data: { seed: 'legacy', type: 'human_name' } },
        ])
        table.reject_ignored_members!
        expect {
          RowTransformer.build(table)
        }.to raise_error(ArgumentError, /seed 'legacy' does not resolve to an extracted column/)
      end

      it 'rejects an unknown fake-data type at load' do
        expect {
          build_table([{ name: 'id' }, { name: 'x', replace_with_fake_data: { seed: 'id', type: 'nope' } }])
        }.to raise_error(ArgumentError, /unknown replace_with_fake_data type 'nope'/)
      end
    end

    describe 'person-family coherence and kana' do
      it 'derives every name column of one seed from the same person (ja full name is "姓 名")' do
        transformer = build_transformer([
          { name: 'id' },
          { name: 'family', replace_with_fake_data: { seed: 'id', type: 'last_name', locale: 'ja' } },
          { name: 'given', replace_with_fake_data: { seed: 'id', type: 'first_name', locale: 'ja' } },
          { name: 'full', replace_with_fake_data: { seed: 'id', type: 'human_name', locale: 'ja' } },
        ])
        _id, family, given, full = transformer.wrap([['1', 'x', 'y', 'z']]).to_a[0]
        expect(full).to eq("#{family} #{given}")
      end

      it 'produces kana matching the kanji person for the same seed' do
        transformer = build_transformer([
          { name: 'id' },
          { name: 'family', replace_with_fake_data: { seed: 'id', type: 'last_name', locale: 'ja' } },
          { name: 'family_kana', replace_with_fake_data: { seed: 'id', type: 'last_name_kana', locale: 'ja' } },
          { name: 'given_kana', replace_with_fake_data: { seed: 'id', type: 'first_name_kana', locale: 'ja' } },
          { name: 'full_kana', replace_with_fake_data: { seed: 'id', type: 'human_name_kana', locale: 'ja' } },
        ])
        _id, family, family_kana, given_kana, full_kana = transformer.wrap([['1', 'a', 'b', 'c', 'd']]).to_a[0]
        pair = JapaneseNames::SURNAMES.find { |kanji, _kana| kanji == family }
        expect(family_kana).to eq(pair[1])
        expect(family_kana).to match(/\A\p{Katakana}+\z/)
        expect(full_kana).to eq("#{family_kana} #{given_kana}")
      end

      it 'orders a non-ja full name as "First Last"' do
        transformer = build_transformer([
          { name: 'id' },
          { name: 'family', replace_with_fake_data: { seed: 'id', type: 'last_name' } },
          { name: 'given', replace_with_fake_data: { seed: 'id', type: 'first_name' } },
          { name: 'full', replace_with_fake_data: { seed: 'id', type: 'human_name' } },
        ])
        _id, family, given, full = transformer.wrap([['1', 'x', 'y', 'z']]).to_a[0]
        expect(full).to eq("#{given} #{family}")
      end

      it 'raises when a kana type is used with a non-ja locale' do
        expect {
          build_transformer([
            { name: 'id' },
            { name: 'k', replace_with_fake_data: { seed: 'id', type: 'last_name_kana' } },
          ])
        }.to raise_error(ArgumentError, /only available with locale: ja/)
      end

      it 'fills the ja person pool with PERSON_POOL_SIZE distinct people' do
        pool = RowTransformer.person_pool('ja')
        expect(pool.size).to eq(RowTransformer::PERSON_POOL_SIZE)
        distinct = pool.map { |p| [p.last_name, p.first_name] }.uniq.size
        expect(distinct).to eq(RowTransformer::PERSON_POOL_SIZE)
      end
    end

    describe RowTransformer::TransformedResult do
      def wrapped(inner)
        build_transformer([{ name: 'id' }, { name: 'name', map: 'proc { |r| "masked" }' }]).wrap(inner)
      end

      it 'delegates #size to the inner result without draining it' do
        inner = Class.new do
          include Enumerable
          def size = 42
          def each = raise 'must not drain'
        end.new
        result = wrapped(inner)
        expect(result.size).to eq(42)
        expect(result.length).to eq(42)
      end

      it 'returns a sized enumerator when #each is called without a block' do
        enum = wrapped([['1', 'a']]).each
        expect(enum).to be_a(Enumerator)
        expect(enum.to_a).to eq([['1', 'masked']])
      end

      it 'streams row by row (works with each_slice like write_inserts does)' do
        slices = wrapped([['1', 'a'], ['2', 'b'], ['3', 'c']]).each_slice(2).to_a
        expect(slices).to eq([[['1', 'masked'], ['2', 'masked']], [['3', 'masked']]])
      end
    end
  end
end
