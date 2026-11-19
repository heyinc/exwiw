# frozen_string_literal: true

require "spec_helper"

module Exwiw
  RSpec.describe Generator do
    describe ".parse" do
      it "reads the kind and the length" do
        generator = described_class.parse("random:16")

        expect(generator.kind).to eq(:random)
        expect(generator.length).to eq(16)
      end

      it "accepts the ends of the length range" do
        expect(described_class.parse("random:1").length).to eq(1)
        expect(described_class.parse("random:256").length).to eq(256)
      end

      [
        "random", "random:", "random:0", "random:257", "random:-1", "random:abc", "random:1.5",
        "random: 8", "random:8 ", "random:8\n", "random:8:9", "foo:8", ":8", "Random:8", "",
      ].each do |spec|
        it "rejects #{spec.inspect}, naming the value and the expected format" do
          expect { described_class.parse(spec) }
            .to raise_error(ArgumentError, /invalid generate value #{Regexp.escape(spec.inspect)}; expected "random:<length>".*1 to 256/)
        end
      end

      it "rejects a value that is not a String" do
        [nil, 8, ["random:8"]].each do |spec|
          expect { described_class.parse(spec) }
            .to raise_error(ArgumentError, /invalid generate value #{Regexp.escape(spec.inspect)}/)
        end
      end
    end

    describe "#call" do
      it "returns an alphanumeric String of the given length" do
        [1, 8, 256].each do |length|
          value = described_class.parse("random:#{length}").call

          expect(value).to be_a(String)
          expect(value.length).to eq(length)
          expect(value).to match(/\A[A-Za-z0-9]+\z/)
        end
      end

      it "returns a different value on every call" do
        generator = described_class.parse("random:32")

        expect(Array.new(100) { generator.call }.uniq.size).to eq(100)
      end

      it "uses every kind of character over many draws" do
        joined = Array.new(50) { described_class.parse("random:256").call }.join

        expect(joined).to match(/[A-Z]/).and match(/[a-z]/).and match(/[0-9]/)
      end
    end
  end
end
