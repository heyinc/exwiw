# frozen_string_literal: true

require "spec_helper"

module Exwiw
  RSpec.describe RandomMask do
    def load(value)
      TableColumn.from_symbol_keys(name: "token", replace_with_random: value)
    end

    it "accepts hex with 16 to 1024 bytes" do
      expect(load("hex:16").replace_with_random).to eq("hex:16")
      expect(load("hex:1024").replace_with_random).to eq("hex:1024")
    end

    it "rejects another format, a size out of range or a non-string" do
      ["hex:15", "hex:1025", "hex:016", "hex", "base64:16", "HEX:16", 16].each do |value|
        expect { load(value) }.to raise_error(Serdes::TypeError), value.inspect
      end
    end

    it "generates that many random bytes as lowercase hex, differing per call" do
      generate = described_class.generator("hex:16")

      values = Array.new(3) { generate.call }
      expect(values).to all(match(/\A[0-9a-f]{32}\z/))
      expect(values.uniq.size).to eq(3)
    end
  end
end
