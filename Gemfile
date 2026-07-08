# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in exwiw.gemspec
gemspec

gem "rake"
gem "rake-compiler" # builds the optional native Extended-JSON extension

gem "rspec"

gem "mysql2"
gem "pg"
gem "sqlite3"
gem "mongo"
gem "mongoid"

# Optional at runtime (lazy-required by replace_with_fake_data masking).
gem "faker"

gem "activerecord"

# Exercises the non-ActiveRecord belongs_to target path (a master with no DB
# table) in schema_generator_non_active_record_belongs_to_spec.
gem "active_hash", group: :test

gem "trilogy", group: :test
