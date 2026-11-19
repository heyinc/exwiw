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

    def load(config_class: TableConfig, reject_ignored: true)
      described_class.new(dir: dir, config_class: config_class, profiles: profiles)
                     .load(reject_ignored: reject_ignored)
    end

    def users(configs)
      configs.find { |c| c.name == "users" }
    end

    it "loads the base configs in file order without a profile" do
      write("users.dev.json", "name" => "users", "filter" => "users.id = 1")

      configs = load

      expect(configs.map(&:name)).to eq(Dir.glob("e2e/sqlite-schema/*.json").sort.map { |f| File.basename(f, ".json") })
      expect(users(configs).filter).to be_nil
    end

    it "reads <x>.<p>.json as a base file when p is not a declared profile" do
      write("users.dev.json", "name" => "users", "primary_key" => "id", "columns" => [{ "name" => "id" }])

      expect { described_class.new(dir: dir, config_class: TableConfig, profiles: []).load }
        .to raise_error(ArgumentError, /'users' is configured twice/)
    end

    it "rejects two base files with the same name" do
      write("accounts.json", JSON.parse(File.read(File.join(dir, "users.json"))))

      expect { load }
        .to raise_error(ArgumentError, %r{'users' is configured twice in .*: .*/accounts.json and .*/users.json})
    end

    it "rejects duplicate belongs_tos in a base config" do
      config = JSON.parse(File.read(File.join(dir, "users.json")))
      config["belongs_tos"] << config["belongs_tos"].first.merge("comment" => "copy")
      write("users.json", config)

      expect { load }
        .to raise_error(ArgumentError, /users.json \('users'\) has more than one belongs_tos\[table_name=shops,foreign_key=shop_id\] entry/)
    end
  end
end
