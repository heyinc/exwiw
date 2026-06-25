# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "active_record"
require "sqlite3"
require "active_hash"

# Regression test for a `belongs_to` whose target is NOT an ActiveRecord model.
#
# A model may `belongs_to` an ActiveHash/ActiveYaml master, e.g.
# `belongs_to :equipment, class_name: "SomeActiveYamlModel"`. With
# `ActiveHash::Associations::ActiveRecordExtensions`, active_hash registers this
# as an ordinary `belongs_to` reflection whose `klass` resolves to the
# ActiveHash class — which has NO database table, so `reflection.table_name`
# (-> `klass.table_name`) raises NoMethodError. `SchemaGenerator` used to call
# `assoc.table_name` on every non-polymorphic belongs_to and would abort the
# whole `schema:generate`. The generator must instead skip the non-AR relation
# (its foreign-key column is still emitted as a plain column).
#
# `OmakaseStartEquipment` (ActiveYaml) in the bongo app is the real-world
# trigger.
module Exwiw
  module SchemaGeneratorNonArFixtures
    # ActiveHash master with no database table — the reflection target that used
    # to crash schema generation.
    class Equipment < ActiveHash::Base
      self.data = [{ id: 1, code: "A" }]
    end

    class OrderItem < ::ActiveRecord::Base
      extend ActiveHash::Associations::ActiveRecordExtensions

      self.table_name = "order_items"

      belongs_to :order, class_name: "Exwiw::SchemaGeneratorNonArFixtures::Order"
      # The offending relation: target is an ActiveHash model, not ActiveRecord.
      belongs_to :equipment, class_name: "Exwiw::SchemaGeneratorNonArFixtures::Equipment"
    end

    class Order < ::ActiveRecord::Base
      self.table_name = "orders"
    end
  end

  RSpec.describe SchemaGenerator do
    describe "belongs_to whose target is not an ActiveRecord model" do
      before(:all) do
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
        conn = ActiveRecord::Base.connection
        conn.create_table(:orders) { |t| t.string :name }
        conn.create_table(:order_items) do |t|
          t.integer :order_id
          t.integer :equipment_id
          t.integer :quantity
        end
      end

      after(:all) do
        ActiveRecord::Base.remove_connection
      end

      around do |ex|
        Dir.mktmpdir do |dir|
          @output_dir = dir
          ex.run
        end
      end

      let(:models) do
        [SchemaGeneratorNonArFixtures::OrderItem, SchemaGeneratorNonArFixtures::Order]
      end
      let(:tables) { described_class.new(models: models, output_dir: @output_dir).build_tables }
      let(:order_items) { tables.find { |t| t.name == "order_items" } }

      it "registers the ActiveHash belongs_to as a reflection (the crash entry point)" do
        equipment = SchemaGeneratorNonArFixtures::OrderItem
          .reflect_on_all_associations(:belongs_to)
          .find { |a| a.name == :equipment }
        expect(equipment).not_to be_nil
        expect(equipment.klass).to eq(SchemaGeneratorNonArFixtures::Equipment)
        expect(equipment.klass).not_to be < ActiveRecord::Base
      end

      it "does not raise on the non-ActiveRecord belongs_to" do
        expect { tables }.not_to raise_error
      end

      it "drops the non-AR relation but keeps the AR one" do
        targets = order_items.belongs_tos.map(&:table_name)
        expect(targets).to include("orders")
        expect(targets).not_to include("equipment")
      end

      it "still emits the foreign-key column of the dropped relation as a plain column" do
        expect(order_items.column_names).to include("equipment_id")
      end
    end
  end
end
