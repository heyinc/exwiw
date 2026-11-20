# frozen_string_literal: true

require "spec_helper"

module Exwiw
  RSpec.describe Schema do
    describe "#check_adapter!" do
      let(:schema) { Schema.new(dir: "schema", profile: nil, config_class: TableConfig, configs: []) }

      it "accepts an adapter that reads the configs it was loaded as" do
        expect { schema.check_adapter!(Adapter::SqliteAdapter) }.not_to raise_error
      end

      it "rejects an adapter that reads another kind of config" do
        expect { schema.check_adapter!(Adapter::MongodbAdapter) }
          .to raise_error(ArgumentError, /loaded as Exwiw::TableConfig, but Exwiw::Adapter::MongodbAdapter reads Exwiw::MongodbCollectionConfig/)
      end
    end
  end
end
