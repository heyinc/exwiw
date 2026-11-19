# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

module Exwiw
  RSpec.describe SchemaLoader do
    let(:dir) { @dir }
    let(:profiles) { ["dev"] }

    around do |example|
      Dir.mktmpdir do |tmp|
        @dir = tmp
        FileUtils.cp(Dir.glob("e2e/sqlite-schema/*.json"), tmp)
        example.run
      end
    end

    def write(file, hash)
      File.write(File.join(dir, file), JSON.pretty_generate(hash))
    end

    def load(profile: "dev", config_class: TableConfig, reject_ignored: true)
      described_class.new(dir: dir, config_class: config_class, profiles: profiles, profile: profile)
                     .load(reject_ignored: reject_ignored)
    end

    def users(configs)
      configs.find { |c| c.name == "users" }
    end

    it "loads the base configs in file order without a profile" do
      write("users.dev.json", "name" => "users", "filter" => "users.id = 1")

      configs = load(profile: nil)

      expect(configs.map(&:name)).to eq(Dir.glob("e2e/sqlite-schema/*.json").sort.map { |f| File.basename(f, ".json") })
      expect(users(configs).filter).to be_nil
    end

    it "merges the selected profile's overlay" do
      write("users.dev.json", "name" => "users", "filter" => "users.id = 1",
                              "columns" => [{ "name" => "name", "replace_with" => "anonymous" }])

      user = users(load)

      expect(user.filter).to eq("users.id = 1")
      column = user.columns.find { |c| c.name == "name" }
      expect(column.raw_sql).to be_nil
      expect(column.replace_with).to eq("anonymous")
    end

    it "ignores the overlays of other profiles" do
      write("users.ci.json", "name" => "users", "filter" => "users.id = 1")

      expect(users(described_class.new(dir: dir, config_class: TableConfig, profiles: %w[dev ci], profile: "dev").load).filter)
        .to be_nil
    end

    it "reads <x>.<p>.json as a base file when p is not a declared profile" do
      write("users.dev.json", "name" => "users", "primary_key" => "id", "columns" => [{ "name" => "id" }])

      expect { described_class.new(dir: dir, config_class: TableConfig, profiles: [], profile: nil).load }
        .to raise_error(ArgumentError, /'users' is configured twice/)
    end

    it "keeps ignored members when asked for the full config, but still validates the runtime one" do
      write("users.dev.json", "name" => "users", "columns" => [{ "name" => "email", "ignore" => true }])

      expect(users(load(reject_ignored: false)).column_names).to include("email")
      expect(users(load).column_names).not_to include("email")
    end

    it "rejects two base files with the same name" do
      write("accounts.json", JSON.parse(File.read(File.join(dir, "users.json"))))

      expect { load(profile: nil) }
        .to raise_error(ArgumentError, %r{'users' is configured twice in .*: .*/accounts.json and .*/users.json})
    end

    it "rejects duplicate belongs_tos in a base config" do
      config = JSON.parse(File.read(File.join(dir, "users.json")))
      config["belongs_tos"] << config["belongs_tos"].first.merge("comment" => "copy")
      write("users.json", config)

      expect { load(profile: nil) }
        .to raise_error(ArgumentError, /users.json \('users'\) has more than one belongs_tos\[table_name=shops,foreign_key=shop_id\] entry/)
    end

    it "rejects an overlay with no base" do
      write("ghosts.dev.json", "name" => "ghosts", "ignore" => true)

      expect { load }.to raise_error(ArgumentError, /ghosts.dev.json: there is no base config named 'ghosts'/)
    end

    it "rejects an overlay without a name" do
      write("users.dev.json", "filter" => "x")

      expect { load }.to raise_error(ArgumentError, /users.dev.json must be a JSON object with a 'name'/)
    end

    it "rejects two overlays of one config for the same profile" do
      write("users.dev.json", "name" => "users", "filter" => "a")
      write("people.dev.json", "name" => "users", "filter" => "b")

      expect { load }.to raise_error(ArgumentError, /'users' has more than one overlay for profile 'dev'/)
    end

    it "names the files when the merged config fails validation" do
      write("users.dev.json", "name" => "users", "primary_key" => nil)

      expect { load }.to raise_error(
        ArgumentError, %r{users.dev.json \(profile 'dev', merged into .*/users.json\): Table 'users' requires primary_key},
      )
    end

    it "fails when the profile leaves a table nothing to extract" do
      columns = JSON.parse(File.read(File.join(dir, "users.json")))["columns"]
      write("users.dev.json", "name" => "users", "columns" => columns.map { |c| { "name" => c["name"], "ignore" => true } })

      expect { load(reject_ignored: false) }.to raise_error(ArgumentError, /users.dev.json .*has no columns to extract/)
    end

    it "merges a MongoDB collection config" do
      Dir.glob(File.join(dir, "*.json")).each { |f| File.delete(f) }
      FileUtils.cp(Dir.glob("e2e/mongodb-schema/*.json"), dir)
      base = JSON.parse(File.read(File.join(dir, "users.json")))
      masked = base["fields"].find { |f| f["replace_with"] }
      write("users.dev.json", "name" => "users", "fields" => [{ "name" => masked["name"], "replace_with" => nil }])

      field = users(load(config_class: MongodbCollectionConfig)).fields.find { |f| f.name == masked["name"] }

      expect(field.replace_with).to be_nil
    end
  end
end
