require 'spec_helper'

module Exwiw
  RSpec.describe MongodbCollectionConfig do
    describe '.from' do
      context 'without embedded_in' do
        let(:json) do
          {
            "name" => "users",
            "primary_key" => "_id",
            "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "shop_id" }],
            "fields" => [
              { "name" => "_id" },
              { "name" => "name", "replace_with" => "masked{_id}" },
              { "name" => "shop_id" },
            ],
          }
        end

        it 'loads a top-level collection config' do
          config = described_class.from(json)
          expect(config.name).to eq("users")
          expect(config.primary_key).to eq("_id")
          expect(config.belongs_tos.map(&:to_hash)).to eq([
            { "table_name" => "shops", "foreign_key" => "shop_id" },
          ])
          expect(config.fields.map(&:to_hash)).to eq([
            { "name" => "_id" },
            { "name" => "name", "replace_with" => "masked{_id}" },
            { "name" => "shop_id" },
          ])
          expect(config.embedded_in).to be_nil
          expect(config.embedded?).to eq(false)
        end
      end

      context 'with embedded_in' do
        let(:json) do
          {
            "name" => "posts",
            "primary_key" => "_id",
            "embedded_in" => { "collection_name" => "users", "path" => "posts" },
            "belongs_tos" => [],
            "fields" => [
              { "name" => "_id" },
              { "name" => "title", "replace_with" => "masked-{_id}" },
            ],
          }
        end

        it 'loads an embedded config and reports embedded? true' do
          config = described_class.from(json)
          expect(config.embedded?).to eq(true)
          expect(config.embedded_in.collection_name).to eq("users")
          expect(config.embedded_in.path).to eq("posts")
        end

        it 'serializes back to a hash with embedded_in' do
          config = described_class.from(json)
          dumped = config.to_hash
          expect(dumped["embedded_in"]).to eq({ "collection_name" => "users", "path" => "posts" })
        end
      end

      context 'when embedded_in is set together with non-empty belongs_tos' do
        let(:json) do
          {
            "name" => "posts",
            "primary_key" => "_id",
            "embedded_in" => { "collection_name" => "users", "path" => "posts" },
            "belongs_tos" => [{ "table_name" => "users", "foreign_key" => "user_id" }],
            "fields" => [{ "name" => "_id" }],
          }
        end

        it 'raises ArgumentError' do
          expect { described_class.from(json) }.to raise_error(ArgumentError, /belongs_tos must be empty/)
        end
      end

      context 'with ignore:true' do
        let(:json) do
          {
            "name" => "logs",
            "primary_key" => "_id",
            "ignore" => true,
            "belongs_tos" => [],
            "fields" => [{ "name" => "_id" }],
          }
        end

        it 'loads ignore and round-trips through to_hash' do
          config = described_class.from(json)
          expect(config.ignore).to eq(true)
          expect(config.to_hash["ignore"]).to eq(true)
        end
      end

      context 'with ignore:true on the primary key field' do
        let(:json) do
          {
            "name" => "orders",
            "primary_key" => "_id",
            "belongs_tos" => [],
            "fields" => [{ "name" => "_id", "ignore" => true }, { "name" => "token" }],
          }
        end

        it 'raises on load (dropping the primary key would break references on restore)' do
          expect { described_class.from(json) }.to raise_error(
            ArgumentError, /primary key '_id' must not be marked ignore: true/
          )
        end
      end

      context 'with an ignored belongs_to carrying ignore_type and no table_name' do
        let(:json) do
          {
            "name" => "orders",
            "primary_key" => "_id",
            "belongs_tos" => [
              { "table_name" => "shops", "foreign_key" => "shop_id" },
              {
                "foreign_key" => "coupon_id",
                "ignore" => true,
                "ignore_type" => "need_code_fix",
                "comment" => "FIXME: target class gone",
              },
            ],
            "fields" => [{ "name" => "_id" }],
          }
        end

        it 'loads the ignored belongs_to (no table_name) and round-trips ignore_type' do
          config = described_class.from(json)
          ignored = config.belongs_tos.find { |b| b.foreign_key == "coupon_id" }
          expect(ignored.table_name).to be_nil
          expect(ignored.ignore).to eq(true)
          expect(ignored.ignore_type).to eq("need_code_fix")
          hash = ignored.to_hash
          expect(hash).not_to have_key("table_name")
          expect(hash["ignore_type"]).to eq("need_code_fix")
        end
      end

      context 'with a non-ignored belongs_to missing table_name' do
        let(:json) do
          {
            "name" => "orders",
            "primary_key" => "_id",
            "belongs_tos" => [{ "foreign_key" => "shop_id" }],
            "fields" => [{ "name" => "_id" }],
          }
        end

        it 'raises ArgumentError (only an ignored belongs_to may omit table_name)' do
          expect { described_class.from(json) }.to raise_error(ArgumentError, /no table_name/)
        end
      end

      context 'with a collection-level ignore_type' do
        let(:json) do
          {
            "name" => "legacy_widgets",
            "primary_key" => "_id",
            "ignore" => true,
            "ignore_type" => "unsupported",
            "comment" => "FIXME: polymorphic embedded_in :owner",
            "belongs_tos" => [],
            "fields" => [{ "name" => "_id" }],
          }
        end

        it 'loads and round-trips ignore_type through to_hash' do
          config = described_class.from(json)
          expect(config.ignore_type).to eq("unsupported")
          expect(config.to_hash["ignore_type"]).to eq("unsupported")
        end
      end

      context 'when fields contain raw_sql key' do
        let(:json) do
          {
            "name" => "users",
            "primary_key" => "_id",
            "belongs_tos" => [],
            "fields" => [
              { "name" => "raw", "raw_sql" => "CONCAT('a','b')" },
            ],
          }
        end

        it 'raises: MongodbField does not declare raw_sql (it was previously a silent no-op)' do
          expect { described_class.from(json) }.to raise_error(
            UnknownConfigKeyError,
            /Unknown key 'raw_sql' in collection 'users' \(in fields\[0\]\)/,
          )
        end
      end

      context 'replace_with_fake_data validation' do
        def config_with_field(field)
          {
            "name" => "users",
            "primary_key" => "_id",
            "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "shop_id" }],
            "fields" => [{ "name" => "_id" }, field],
          }
        end

        it 'accepts a valid fake-data field seeded by the primary key' do
          json = config_with_field(
            "name" => "name", "replace_with_fake_data" => { "seed" => "_id", "type" => "human_name" },
          )
          config = described_class.from(json)
          field = config.fields.find { |f| f.name == "name" }
          expect(field.replace_with_fake_data.type).to eq("human_name")
          expect(field.replace_with_fake_data.seed).to eq("_id")
        end

        it 'accepts a collection-qualified seed naming a declared field' do
          json = config_with_field(
            "name" => "name", "replace_with_fake_data" => { "seed" => "users._id", "type" => "human_name" },
          )
          expect { described_class.from(json) }.not_to raise_error
        end

        it 'rejects combining replace_with with replace_with_fake_data' do
          json = config_with_field(
            "name" => "name",
            "replace_with" => "x-{_id}",
            "replace_with_fake_data" => { "seed" => "_id", "type" => "human_name" },
          )
          expect { described_class.from(json) }.to raise_error(ArgumentError, /cannot be combined/)
        end

        it 'rejects an unknown fake-data type' do
          json = config_with_field(
            "name" => "name", "replace_with_fake_data" => { "seed" => "_id", "type" => "wat" },
          )
          expect { described_class.from(json) }.to raise_error(ArgumentError, /unknown replace_with_fake_data type 'wat'/)
        end

        it 'rejects a seed that names no field of this collection' do
          json = config_with_field(
            "name" => "name", "replace_with_fake_data" => { "seed" => "other.id", "type" => "human_name" },
          )
          expect { described_class.from(json) }.to raise_error(ArgumentError, /does not name a field of this collection/)
        end

        it 'rejects an unknown key nested inside replace_with_fake_data' do
          json = config_with_field(
            "name" => "name",
            "replace_with_fake_data" => { "seed" => "_id", "type" => "human_name", "lcoale" => "ja" },
          )
          expect { described_class.from(json) }.to raise_error(
            UnknownConfigKeyError,
            /Unknown key 'lcoale' in collection 'users' \(in fields\[1\]\.replace_with_fake_data\)/,
          )
        end
      end

      context 'strict unknown-key validation' do
        let(:base_json) do
          {
            "name" => "users",
            "primary_key" => "_id",
            "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "shop_id" }],
            "fields" => [{ "name" => "_id" }],
          }
        end

        it 'rejects an unknown top-level key, naming the key and the collection' do
          expect { described_class.from(base_json.merge("reverse_scop" => { "via" => [] })) }.to raise_error(
            UnknownConfigKeyError,
            /Unknown key 'reverse_scop' in collection 'users'\. Allowed keys: .*reverse_scope/,
          )
        end

        it 'rejects an unknown key inside a belongs_to entry with its position' do
          json = base_json.merge(
            "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "shop_id", "foreign_keu" => "x" }],
          )
          expect { described_class.from(json) }.to raise_error(
            UnknownConfigKeyError,
            /Unknown key 'foreign_keu' in collection 'users' \(in belongs_tos\[0\]\)/,
          )
        end

        it 'rejects an unknown key inside a reverse_scope via arm' do
          json = base_json.merge(
            "belongs_tos" => [],
            "reverse_scope" => { "via" => [{ "table" => "articles", "column" => "user_id", "colunm" => "typo" }] },
          )
          expect { described_class.from(json) }.to raise_error(
            UnknownConfigKeyError,
            /Unknown key 'colunm' in collection 'users' \(in reverse_scope\.via\[0\]\)/,
          )
        end

        it 'keeps accepting comment everywhere it is declared (documentation key)' do
          json = base_json.merge(
            "comment" => "collection note",
            "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "shop_id", "comment" => "bt note" }],
            "fields" => [{ "name" => "_id", "comment" => "field note" }],
          )
          expect { described_class.from(json) }.not_to raise_error
        end
      end

      context 'with reverse_scope' do
        let(:json) do
          {
            "name" => "accounts",
            "primary_key" => "_id",
            "reverse_scope" => {
              "via" => [
                { "table" => "articles", "column" => "author_account_id" },
                { "table" => "invitations", "column" => "invitee_account_id" },
              ],
            },
            "belongs_tos" => [],
            "fields" => [{ "name" => "_id" }],
          }
        end

        it 'loads the via arms and round-trips them through to_hash' do
          config = described_class.from(json)
          expect(config.reverse_scope.via.map { |v| [v.table, v.column] }).to eq([
            %w[articles author_account_id],
            %w[invitations invitee_account_id],
          ])
          expect(config.to_hash["reverse_scope"]).to eq(json["reverse_scope"])
        end

        it 'is omitted from to_hash when not set' do
          config = described_class.from(json.except("reverse_scope"))
          expect(config.reverse_scope).to be_nil
          expect(config.to_hash).not_to have_key("reverse_scope")
        end
      end

      context 'when reverse_scope is set on an embedded config' do
        let(:json) do
          {
            "name" => "posts",
            "primary_key" => "_id",
            "embedded_in" => { "collection_name" => "users", "path" => "posts" },
            "reverse_scope" => { "via" => [{ "table" => "articles", "column" => "post_id" }] },
            "belongs_tos" => [],
            "fields" => [{ "name" => "_id" }],
          }
        end

        it 'raises (an embedded config is never dumped on its own)' do
          expect { described_class.from(json) }.to raise_error(ArgumentError, /reverse_scope must not be defined/)
        end
      end
    end

    describe '#merge' do
      let(:current) do
        described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id', references: 'uuid', comment: 'bt note', ignore: true }],
          fields: [
            { name: '_id' },
            { name: 'token', comment: 'secret', ignore: true, replace_with: 'X' },
          ],
        )
      end
      let(:passed) do
        described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id' }],
          fields: [{ name: '_id' }, { name: 'token' }, { name: 'extra' }],
        )
      end

      it 'preserves user-owned comment/ignore/references on belongs_tos' do
        # `references` (the non-_id parent field a FK points at) is hand-added and
        # the generator never emits it, so the merge must carry it forward rather
        # than letting re-introspection drop it.
        merged = current.merge(passed)
        expect(merged.belongs_tos.map(&:to_hash)).to eq([
          { 'table_name' => 'shops', 'foreign_key' => 'shop_id', 'references' => 'uuid', 'comment' => 'bt note', 'ignore' => true },
        ])
      end

      it 'preserves user-owned comment/ignore/replace_with on fields while tracking added fields' do
        merged = current.merge(passed)
        token = merged.fields.find { |f| f.name == 'token' }
        expect(token.to_hash).to eq({ 'name' => 'token', 'replace_with' => 'X', 'comment' => 'secret', 'ignore' => true })
        expect(merged.fields.map(&:name)).to eq(['_id', 'token', 'extra'])
      end

      it 'lets the on-disk needs_mask_decision state win over a regenerated one' do
        current_flagged = described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id' }],
          fields: [
            { name: '_id' },
            { name: 'memo', replace_with: 'masked', needs_mask_decision: true },
            { name: 'decided', replace_with: 'masked' },
          ],
        )
        regenerated = described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id' }],
          fields: [
            { name: '_id' },
            { name: 'memo' },
            { name: 'decided', needs_mask_decision: true },
          ],
        )
        merged = current_flagged.merge(regenerated)

        expect(merged.fields.find { |f| f.name == 'memo' }.needs_mask_decision).to eq(true)
        expect(merged.fields.find { |f| f.name == 'decided' }.needs_mask_decision).to be_nil
      end

      it 'keeps a field the user unmasked unmasked, even when regeneration proposes a default mask' do
        # Safe mode (MongoidSchemaGenerator#safe_new_columns) makes the generated
        # side carry a default mask for every field, so "the receiver has none"
        # can no longer mean "take the generated one": an absent replace_with is
        # itself the decision (export this field raw), and re-masking it on every
        # regeneration would silently undo it. Same for a resolved
        # needs_mask_decision, which must stay resolved.
        decided = described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id' }],
          fields: [
            { name: '_id' },
            { name: 'memo', comment: 'reviewed: no personal data' },
          ],
        )
        regenerated_safe = described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id' }],
          fields: [
            { name: '_id', needs_mask_decision: true },
            { name: 'memo', replace_with: 'masked-{_id}', needs_mask_decision: true },
          ],
        )
        merged = decided.merge(regenerated_safe)

        memo = merged.fields.find { |f| f.name == 'memo' }
        expect(memo.to_hash).to eq({ 'name' => 'memo', 'comment' => 'reviewed: no personal data' })
        expect(merged.fields.find { |f| f.name == '_id' }.needs_mask_decision).to be_nil
      end

      it 'preserves a user-owned replace_with_fake_data on a field across regeneration' do
        current_with_fake = described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id' }],
          fields: [
            { name: '_id' },
            { name: 'buyer_name', replace_with_fake_data: { seed: '_id', type: 'human_name' } },
          ],
        )
        regenerated = described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id' }],
          fields: [{ name: '_id' }, { name: 'buyer_name' }],
        )
        merged = current_with_fake.merge(regenerated)
        buyer = merged.fields.find { |f| f.name == 'buyer_name' }
        expect(buyer.replace_with_fake_data.type).to eq('human_name')
        expect(buyer.replace_with_fake_data.seed).to eq('_id')
      end

      it 'carries the user-owned query_timeout_ms forward (the generator never emits it)' do
        current.query_timeout_ms = 120_000
        merged = current.merge(passed)
        expect(merged.query_timeout_ms).to eq(120_000)
      end

      it 'carries the user-owned reverse_scope forward (the generator never emits it)' do
        current.reverse_scope = ReverseScope.from(
          'via' => [{ 'table' => 'articles', 'column' => 'author_account_id' }],
        )
        merged = current.merge(passed)
        expect(merged.reverse_scope.via.map { |v| [v.table, v.column] }).to eq([%w[articles author_account_id]])
      end
    end

    describe 'query_timeout_ms serialization' do
      it 'round-trips when set and is omitted from the hash when nil' do
        with_timeout = described_class.from_symbol_keys(
          name: 'orders', primary_key: '_id', belongs_tos: [], fields: [], query_timeout_ms: 90_000,
        )
        expect(with_timeout.to_hash).to include('query_timeout_ms' => 90_000)

        without_timeout = described_class.from_symbol_keys(
          name: 'orders', primary_key: '_id', belongs_tos: [], fields: [],
        )
        expect(without_timeout.to_hash).not_to have_key('query_timeout_ms')
      end
    end

    describe '#reject_ignored_members!' do
      let(:config) do
        described_class.from_symbol_keys(
          name: 'orders',
          primary_key: '_id',
          belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id', ignore: true }],
          fields: [{ name: '_id' }, { name: 'token', ignore: true }],
        )
      end

      it 'drops belongs_tos and fields flagged ignore:true' do
        config.reject_ignored_members!
        expect(config.belongs_tos).to eq([])
        expect(config.fields.map(&:name)).to eq(['_id'])
      end

      it 'returns self so it can be chained after load' do
        expect(config.reject_ignored_members!).to be(config)
      end

      it 'still reports the ignored field names once the entries are dropped' do
        # An embedded config's ignored fields are removed from the subdocuments
        # during masking, which runs long after the entries themselves are gone.
        config.reject_ignored_members!
        expect(config.ignored_field_names).to eq(['token'])
      end
    end

    describe '.from_symbol_keys' do
      it 'accepts symbol keys' do
        config = described_class.from_symbol_keys(
          name: "users",
          primary_key: "_id",
          belongs_tos: [],
          fields: [{ name: "_id" }],
        )
        expect(config.name).to eq("users")
        expect(config.fields.first.name).to eq("_id")
      end
    end
  end
end
