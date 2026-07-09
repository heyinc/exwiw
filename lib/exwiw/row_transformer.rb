# frozen_string_literal: true

require "digest"

require_relative "japanese_names"

module Exwiw
  # Applies the Ruby-process-side masking modes — `map` and
  # `replace_with_fake_data` — to the rows streamed out of a SQL adapter's
  # #execute. Unlike replace_with/raw_sql, which compile into the SELECT and
  # run in the database, these run in the exwiw process, so they can execute
  # arbitrary Ruby (`map`) or derive deterministic fake values (`fake data`).
  #
  # Built once per table (.build compiles the map procs, resolves seed column
  # indexes, and pre-generates the fake-value pools), then #wrap decorates the
  # adapter's StreamingResult: rows are transformed one at a time as the
  # stream is drained, so the bounded-memory profile of the streaming dump is
  # preserved. #size delegates to the underlying result, keeping the COPY
  # path's upfront count and each_slice's allocation-hint COUNT identical to
  # an unwrapped run.
  #
  # SQL adapters only: .build returns nil for configs without a `columns`
  # list (MongodbCollectionConfig has `fields`; rails-managed tables have no
  # columns), and for tables where no column carries a Ruby-side mode.
  class RowTransformer
    # Fake values are picked from a pool of this many pre-generated values.
    # Distinct seed values beyond the pool size reuse pool entries (fine for
    # fake data — determinism, not uniqueness, is the contract; uniqueness-
    # sensitive types compose a 64-bit token on top, see FAKE_TYPES).
    POOL_SIZE = 10_000

    # Fixed Random seed for pool generation, so a pool is deterministic for a
    # given faker gem version + locale.
    POOL_RANDOM_SEED = 715_517

    # A coherent fake identity. All person-family types (PERSON_TYPES) draw
    # from one shared pool of these per locale, and a seed picks the same pool
    # index for every such column — so last_name / first_name / full name (and
    # their kana) for one seed all belong to the same person. kana fields are
    # only populated for the `ja` locale (faker has no readings; exwiw bundles
    # a paired dataset — see JapaneseNames); they are nil otherwise.
    Person = Struct.new(:last_name, :first_name, :last_name_kana, :first_name_kana)

    # Person-family types: they share the per-locale person pool (built by
    # .person_pool), and each extractor derives its value from the picked
    # Person. Full-name ordering is locale-aware ("姓 名" for ja, "First Last"
    # elsewhere). This is what keeps a single seed's name columns consistent.
    PERSON_TYPES = {
      "human_name"      => ->(p, locale) { join_full_name(p.last_name, p.first_name, locale) },
      "last_name"       => ->(p, _locale) { p.last_name },
      "first_name"      => ->(p, _locale) { p.first_name },
      "human_name_kana" => ->(p, locale) { join_full_name(p.last_name_kana, p.first_name_kana, locale) },
      "last_name_kana"  => ->(p, _locale) { p.last_name_kana },
      "first_name_kana" => ->(p, _locale) { p.first_name_kana },
    }.freeze

    # Person-family types whose value is a kana reading, only available for the
    # `ja` locale (the person pool carries nil kana for other locales, so these
    # are rejected at build time with a clear error).
    KANA_TYPES = %w[human_name_kana last_name_kana first_name_kana].freeze

    # Independent (non-person) types. `pool` builds one candidate value (called
    # POOL_SIZE times under a seeded Faker random). Types with `compose` are
    # uniqueness-sensitive: the pooled base alone would collide under a unique
    # index at scale, so the final value composes the base with a 64-bit hex
    # token derived from the same seed digest (collision probability at 5M
    # distinct seeds ≈ 7e-7).
    FAKE_TYPES = {
      "phone_number" => { pool: -> { Faker::PhoneNumber.phone_number } },
      "address"      => { pool: -> { Faker::Address.full_address } },
      "company_name" => { pool: -> { Faker::Company.name } },
      "email"        => { pool: -> { Faker::Internet.username(specifier: 5..12) },
                          compose: ->(base, token) { "#{base}.#{token}@example.com" } },
      "username"     => { pool: -> { Faker::Internet.username(specifier: 5..12) },
                          compose: ->(base, token) { "#{base}_#{token}" } },
    }.freeze

    # "姓 名" for Japanese, "First Last" otherwise. A nil part (e.g. missing
    # kana) collapses so the result never has a dangling separator.
    def self.join_full_name(last, first, locale)
      parts = locale.to_s == "ja" ? [last, first] : [first, last]
      parts.compact.join(" ")
    end

    # The `r` a map proc receives: read-only access to the current row's
    # values by column name (`r['id']`). One instance is reused across all
    # rows (zero per-row allocation) — do not retain it outside the proc.
    class Row
      def initialize(table_name, name_to_index)
        @table_name = table_name
        @name_to_index = name_to_index
        @values = nil
      end

      attr_writer :values

      def [](column_name)
        index = @name_to_index[column_name]
        unless index
          raise ArgumentError,
                "unknown column '#{column_name}' in map proc for table '#{@table_name}' " \
                "(available: #{@name_to_index.keys.join(', ')})"
        end
        @values[index]
      end
    end

    # Lazy Enumerable decorator returned by #wrap. Mirrors the adapters'
    # StreamingResult contract (#size COUNT delegation, sized enum_for, #each
    # returning self) so it is a drop-in for both write_inserts and
    # to_copy_from_stdin.
    class TransformedResult
      include Enumerable

      def initialize(inner, transformer)
        @inner = inner
        @transformer = transformer
      end

      def size
        @inner.size
      end
      alias length size

      def each
        return enum_for(:each) { size } unless block_given?

        @inner.each { |row| yield @transformer.transform(row) }
        self
      end
    end

    # -> RowTransformer | nil. nil when the table carries no Ruby-side mode,
    # so the Runner can skip wrapping entirely (the unused path stays
    # byte-identical and cost-free).
    def self.build(table)
      return nil unless table.respond_to?(:columns)

      columns = table.columns
      return nil if columns.nil? || columns.none? { |c| c.map || c.replace_with_fake_data }

      new(table)
    end

    def self.require_faker!
      require "faker"
    rescue LoadError
      raise LoadError,
            "replace_with_fake_data requires the faker gem. " \
            "Add `gem \"faker\"` to your Gemfile (it is not a runtime dependency of exwiw)."
    end

    # Whether a (type, locale) draws any value from faker. The `ja` person pool
    # is built entirely from exwiw's bundled dataset, so a config that only
    # uses `ja` person types needs no faker at all.
    def self.type_needs_faker?(type, locale)
      return true if FAKE_TYPES.key?(type)

      PERSON_TYPES.key?(type) && locale.to_s != "ja"
    end

    # Pools are memoized per (type, locale): every column sharing a type+locale
    # sees the same pool, which is what makes equal seed values map to equal
    # fake values across tables and runs.
    def self.fake_pool(type, locale)
      @fake_pools ||= {}
      @fake_pools[[type, locale]] ||= build_fake_pool(type, locale)
    end

    def self.build_fake_pool(type, locale)
      spec = FAKE_TYPES.fetch(type)
      previous_locale = Faker::Config.locale
      previous_random = Faker::Config.random
      Faker::Config.locale = locale if locale
      Faker::Config.random = Random.new(POOL_RANDOM_SEED)
      Array.new(POOL_SIZE) { spec[:pool].call.freeze }.freeze
    ensure
      Faker::Config.locale = previous_locale
      Faker::Config.random = previous_random
    end

    # One pool of coherent Person records per locale, shared by every
    # person-family type. Memoized so equal seeds map to equal people across
    # tables and runs. `ja` is built from exwiw's bundled (kanji, kana) dataset
    # so kana matches kanji; other locales use faker (no kana).
    def self.person_pool(locale)
      @person_pools ||= {}
      @person_pools[locale] ||= build_person_pool(locale)
    end

    def self.build_person_pool(locale)
      random = Random.new(POOL_RANDOM_SEED)
      return build_japanese_person_pool(random) if locale.to_s == "ja"

      previous_locale = Faker::Config.locale
      previous_random = Faker::Config.random
      Faker::Config.locale = locale if locale
      Faker::Config.random = random
      Array.new(POOL_SIZE) { Person.new(Faker::Name.last_name, Faker::Name.first_name, nil, nil).freeze }.freeze
    ensure
      unless locale.to_s == "ja"
        Faker::Config.locale = previous_locale
        Faker::Config.random = previous_random
      end
    end

    def self.build_japanese_person_pool(random)
      surnames = JapaneseNames::SURNAMES
      given_names = JapaneseNames::GIVEN_NAMES
      Array.new(POOL_SIZE) do
        last = surnames[random.rand(surnames.size)]
        first = given_names[random.rand(given_names.size)]
        Person.new(last[0], first[0], last[1], first[1]).freeze
      end.freeze
    end

    def initialize(table)
      @table_name = table.name
      @name_to_index = {}
      table.columns.each_with_index { |column, index| @name_to_index[column.name] = index }
      @name_to_index.freeze
      @row_accessor = Row.new(@table_name, @name_to_index)

      needs_faker = table.columns.any? do |column|
        fd = column.replace_with_fake_data
        fd && self.class.type_needs_faker?(fd.type, fd.locale)
      end
      self.class.require_faker! if needs_faker

      @transforms = table.columns.each_with_index.filter_map do |column, index|
        if column.map
          [index, compile_map(column)]
        elsif column.replace_with_fake_data
          [index, compile_fake(column, index)]
        end
      end
      @replacement_buffer = Array.new(@transforms.size)
    end

    def wrap(results)
      TransformedResult.new(results, self)
    end

    # Replacements are all computed from the original row before any is
    # written back, so a map proc / fake seed always reads the pre-transform
    # (post-SQL-masking) value regardless of column order. Rows are mutated in
    # place when possible (each cursor yields a fresh Array per row), but
    # sqlite3's Statement#each yields frozen rows — those are duped first.
    def transform(row)
      @transforms.each_with_index do |(_, callable), k|
        @replacement_buffer[k] = callable.call(row)
      end
      row = row.dup if row.frozen?
      @transforms.each_with_index do |(index, _), k|
        row[index] = @replacement_buffer[k]
      end
      row
    end

    private def compile_map(column)
      # eval is the documented contract of `map`: the schema config supplies a
      # Ruby proc source and exwiw runs it. Configs are trusted local files
      # (same trust level as the Gemfile); the README warns to only load
      # trusted configs. Evaluated once per table, at dump time only — never
      # during schema generation/regeneration.
      evaluated =
        begin
          eval(column.map, TOPLEVEL_BINDING.dup, "(exwiw map for #{@table_name}.#{column.name})") # rubocop:disable Security/Eval
        rescue StandardError, ScriptError => e
          raise ArgumentError,
                "map for column '#{@table_name}.#{column.name}' failed to eval: #{e.class}: #{e.message}"
        end
      unless evaluated.is_a?(Proc)
        raise ArgumentError,
              "map for column '#{@table_name}.#{column.name}' must evaluate to a Proc, got #{evaluated.class}"
      end

      row_accessor = @row_accessor
      table_name = @table_name
      column_name = column.name
      lambda do |row|
        row_accessor.values = row
        begin
          evaluated.call(row_accessor)
        rescue StandardError => e
          raise "map proc for column '#{table_name}.#{column_name}' raised: #{e.class}: #{e.message}"
        end
      end
    end

    private def compile_fake(column, column_index)
      fake_data = column.replace_with_fake_data
      type = fake_data.type
      unless PERSON_TYPES.key?(type) || FAKE_TYPES.key?(type)
        raise ArgumentError,
              "replace_with_fake_data for column '#{@table_name}.#{column.name}': " \
              "unknown type '#{type}'. Supported: #{(PERSON_TYPES.keys + FAKE_TYPES.keys).join(', ')}"
      end

      seed_index = resolve_seed_index(fake_data, column)

      if PERSON_TYPES.key?(type)
        compile_person_fake(fake_data, column, column_index, seed_index)
      else
        compile_independent_fake(fake_data, column_index, seed_index)
      end
    end

    # Re-resolve the seed here, against the effective (post-ignore) columns:
    # load-time validation sees the full column list, so a seed column that was
    # ignore:true is only caught at dump time.
    private def resolve_seed_index(fake_data, column)
      seed_column = fake_data.seed.delete_prefix("#{@table_name}.")
      seed_index = @name_to_index[seed_column]
      unless seed_index
        raise ArgumentError,
              "replace_with_fake_data for column '#{@table_name}.#{column.name}': " \
              "seed '#{fake_data.seed}' does not resolve to an extracted column " \
              "(is it ignore:true?)"
      end
      seed_index
    end

    # Person-family type: pick a coherent Person from the per-locale pool. The
    # digest[0,8] index is shared with every other person column, so one seed's
    # name columns all belong to the same person.
    private def compile_person_fake(fake_data, column, column_index, seed_index)
      type = fake_data.type
      locale = fake_data.locale
      pool = self.class.person_pool(locale)
      extractor = PERSON_TYPES.fetch(type)

      if KANA_TYPES.include?(type) && pool.first.last_name_kana.nil?
        raise ArgumentError,
              "replace_with_fake_data for column '#{@table_name}.#{column.name}': " \
              "type '#{type}' needs kana readings, which are only available with locale: ja " \
              "(got locale: #{locale.inspect})"
      end

      # NULL-preserving like replace_with: a NULL target stays NULL.
      lambda do |row|
        next nil if row[column_index].nil?

        digest = Digest::SHA256.digest(row[seed_index].to_s)
        person = pool[digest[0, 8].unpack1("Q>") % POOL_SIZE]
        extractor.call(person, locale)
      end
    end

    # Independent type: pick a value from its own (type, locale) pool.
    private def compile_independent_fake(fake_data, column_index, seed_index)
      pool = self.class.fake_pool(fake_data.type, fake_data.locale)
      compose = FAKE_TYPES.fetch(fake_data.type)[:compose]

      # NULL-preserving like replace_with: a NULL target stays NULL. A nil seed
      # value hashes "" (deterministic). Seed values are normalized with to_s so
      # sqlite's native Integer 123 and pg/mysql's string "123" pick the same
      # fake value.
      lambda do |row|
        next nil if row[column_index].nil?

        digest = Digest::SHA256.digest(row[seed_index].to_s)
        base = pool[digest[0, 8].unpack1("Q>") % POOL_SIZE]
        compose ? compose.call(base, digest[8, 8].unpack1("H*")) : base
      end
    end
  end
end
