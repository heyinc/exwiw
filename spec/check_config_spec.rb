# frozen_string_literal: true

require "spec_helper"

module Exwiw
  RSpec.describe CheckConfig do
    def parse(value, profiles: %w[dev])
      described_class.parse(value, profiles: profiles, source: "exwiw.yml")
    end

    describe "defaults" do
      it "runs only integrity, against the base config and every declared profile, when check is absent" do
        config = parse(nil)

        expect(config.enabled).to eq(%w[integrity])
        expect(config.profiles_by_check).to eq("integrity" => [nil, "dev"])
        expect(config.mask_patterns).to eq(MaskRules::DEFAULT_MASK_PATTERNS)
      end

      it "keeps the default of an item that is not mentioned" do
        expect(parse({ "masks" => {} }).enabled).to eq(%w[integrity masks])
      end
    end

    describe "item values" do
      it "enables an item with true or a mapping, and disables it with false" do
        config = parse({ "integrity" => false, "credentials" => true, "masks" => {} })

        expect(config.enabled).to eq(%w[credentials masks])
        expect(config.enabled?("integrity")).to be(false)
      end

      it "rejects any other value" do
        expect { parse({ "masks" => "yes" }) }
          .to raise_error(ArgumentError, /'check.masks' must be true, false or a mapping of options \(got "yes"\) in exwiw.yml/)
        expect { parse({ "masks" => nil }) }.to raise_error(ArgumentError, /'check.masks' must be true, false or a mapping/)
      end

      it "rejects a check section that is not a mapping" do
        expect { parse(%w[masks]) }.to raise_error(ArgumentError, /'check' must be a mapping of integrity, credentials, masks/)
      end
    end

    describe "unknown keys" do
      it "rejects an unknown check" do
        expect { parse({ "secrets" => true }) }.to raise_error(ArgumentError, /unknown check\(s\) secrets under 'check'/)
      end

      it "rejects an unknown option, and patterns anywhere but masks" do
        expect { parse({ "masks" => { "pattern" => [] } }) }
          .to raise_error(ArgumentError, /unknown option\(s\) pattern under 'check.masks'.*allowed: profiles, patterns/)
        expect { parse({ "credentials" => { "patterns" => [] } }) }
          .to raise_error(ArgumentError, /unknown option\(s\) patterns under 'check.credentials'/)
      end
    end

    describe "profiles" do
      it "maps base to the base config and keeps the declared profiles named" do
        config = parse({ "masks" => { "profiles" => %w[dev base] } })

        expect(config.profiles_by_check["masks"]).to eq(["dev", nil])
        expect(config.profiles).to eq([nil, "dev"])
      end

      it "rejects an undeclared profile" do
        expect { parse({ "credentials" => { "profiles" => %w[base staging] } }) }
          .to raise_error(ArgumentError, /'check.credentials.profiles' names undeclared profile\(s\) staging.*declared profiles: dev/)
      end

      it "rejects an empty or malformed list" do
        expect { parse({ "masks" => { "profiles" => [] } }) }
          .to raise_error(ArgumentError, /must be a non-empty list of profile names.*set 'check.masks: false'/)
        expect { parse({ "masks" => { "profiles" => "base" } }) }
          .to raise_error(ArgumentError, /must be a non-empty list of profile names/)
      end

      it "runs against the base config alone when no profile is declared" do
        expect(parse(nil, profiles: []).profiles_by_check).to eq("integrity" => [nil])
      end
    end

    describe "patterns" do
      it "appends the configured patterns, case-insensitive, to the defaults" do
        config = parse({ "masks" => { "patterns" => ["(^|_)kana(_|$)"] } })

        expect(config.mask_patterns.first(MaskRules::DEFAULT_MASK_PATTERNS.size)).to eq(MaskRules::DEFAULT_MASK_PATTERNS)
        expect(config.mask_patterns.last).to eq(/(^|_)kana(_|$)/i)
      end

      it "names an invalid regular expression" do
        expect { parse({ "masks" => { "patterns" => ["ok", "kana("] } }) }
          .to raise_error(ArgumentError, /'check.masks.patterns' has an invalid regular expression "kana\(" in exwiw.yml/)
      end

      it "rejects patterns that are not a list of strings" do
        expect { parse({ "masks" => { "patterns" => "kana" } }) }
          .to raise_error(ArgumentError, /'check.masks.patterns' must be a list of regular expressions/)
      end
    end
  end
end
