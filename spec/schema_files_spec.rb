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
  end
end
