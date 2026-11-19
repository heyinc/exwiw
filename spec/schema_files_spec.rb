# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

module Exwiw
  RSpec.describe SchemaFiles do
    describe ".overlay_profile" do
      it "recognizes <table>.<profile>.json for a declared profile only" do
        expect(described_class.overlay_profile("s/users.dev.json", ["dev"])).to eq("dev")
        expect(described_class.overlay_profile("s/users.ci.json", ["dev"])).to be_nil
        expect(described_class.overlay_profile("s/users.json", ["dev"])).to be_nil
        expect(described_class.overlay_profile("s/.dev.json", ["dev"])).to be_nil
      end
    end

    describe "file listing" do
      it "separates base files from overlays, sorted, recursively when asked" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "primary"))
          %w[users.json shops.json users.dev.json users.ci.json primary/orders.json primary/orders.dev.json].each do |f|
            File.write(File.join(dir, f), "{}")
          end

          names = ->(paths) { paths.map { |p| p.delete_prefix("#{dir}/") } }
          expect(names.(described_class.base_files(dir, ["dev"]))).to eq(%w[shops.json users.ci.json users.json])
          expect(names.(described_class.overlay_files(dir, %w[dev ci]))).to eq(%w[users.ci.json users.dev.json])
          expect(names.(described_class.overlay_files(dir, %w[dev ci], profile: "ci"))).to eq(%w[users.ci.json])
          expect(names.(described_class.overlay_files_recursive(dir, ["dev"]))).to eq(%w[primary/orders.dev.json users.dev.json])
          expect(names.(described_class.base_files_recursive(dir, ["dev"])))
            .to eq(%w[primary/orders.json shops.json users.ci.json users.json])
        end
      end
    end

    describe ".ensure_base_name!" do
      it "rejects a table whose file name would read as an overlay" do
        expect { described_class.ensure_base_name!("users.dev", ["dev"]) }.to raise_error(ArgumentError, /overlay of profile 'dev'/)
        expect { described_class.ensure_base_name!("users.dev", []) }.not_to raise_error
      end
    end
  end
end
