# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "active_record"
require "sqlite3"

# Regression test for the `left_side_id` bug in schema_generate.
#
# When a model declares `has_and_belongs_to_many`, Rails builds an *anonymous
# join model* (named `HABTM_<Association>`) to back the relation. That join
# model:
#   - is a concrete (non-abstract) descendant of ActiveRecord::Base,
#   - reports the join table as its `table_name` (e.g. "posts_tags"),
#   - and declares `belongs_to :left_side` plus the right-side `belongs_to`.
#
# `SchemaGenerator.from_rails_application` enumerates
# `ActiveRecord::Base.descendants`, so these HABTM_* join models get swept in
# just like real models. The synthetic `:left_side` belongs_to has no explicit
# foreign_key, so AR derives one from the association *name* -> "left_side_id",
# a column that does not exist in the join table. Before the fix the generator
# emitted that bogus `left_side_id` foreign key into the join table's config.
module Exwiw
  module SchemaGeneratorHabtmFixtures
    # Post <-> PostTag <-> Tag: a plain many-to-many over the `posts_tags` join
    # table, whose real columns are `post_id` and `tag_id`.
    class Post < ::ActiveRecord::Base
      self.table_name = "posts"
      has_and_belongs_to_many :tags,
                              join_table: "posts_tags",
                              class_name: "Exwiw::SchemaGeneratorHabtmFixtures::Tag"
    end

    class Tag < ::ActiveRecord::Base
      self.table_name = "tags"
      has_and_belongs_to_many :posts,
                              join_table: "posts_tags",
                              class_name: "Exwiw::SchemaGeneratorHabtmFixtures::Post"
    end

    # An explicit join model on the same table (the common pattern of keeping a
    # model around for the join rows). Its belongs_tos are the correct ones
    # (post_id / tag_id); the bogus `left_side_id` came purely from the
    # anonymous HABTM_* models.
    class PostTag < ::ActiveRecord::Base
      self.table_name = "posts_tags"
      belongs_to :post, class_name: "Exwiw::SchemaGeneratorHabtmFixtures::Post"
      belongs_to :tag, class_name: "Exwiw::SchemaGeneratorHabtmFixtures::Tag"
    end

    module_function

    # Rails builds the HABTM_* join models lazily, the first time the relation
    # is reflected on. Force that here so the join models show up in
    # `ActiveRecord::Base.descendants`, exactly as they would after
    # `Rails.application.eager_load!`.
    def join_models
      [Post, Tag].each do |m|
        m.reflect_on_all_associations(:has_and_belongs_to_many).each(&:klass)
      end
      ::ActiveRecord::Base.descendants.select { |m| m.name.to_s.include?("HABTM_") }
    end
  end

  RSpec.describe SchemaGenerator do
    describe "has_and_belongs_to_many join model handling" do
      before(:all) do
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
        conn = ActiveRecord::Base.connection
        conn.create_table(:posts) { |t| t.string :title }
        conn.create_table(:tags) { |t| t.string :name }
        # A normal join table backing the `PostTag` model: it has an `id`
        # primary key plus post_id / tag_id. There is no `left_side_id` column
        # anywhere.
        conn.create_table(:posts_tags) do |t|
          t.integer :post_id
          t.integer :tag_id
        end
      end

      after(:all) do
        ActiveRecord::Base.remove_connection
      end

      let(:output_dir) { @output_dir }

      around do |ex|
        Dir.mktmpdir do |dir|
          @output_dir = dir
          ex.run
        end
      end

      # `from_rails_application` feeds `ActiveRecord::Base.descendants` to the
      # generator, which is where the HABTM_* join models leak in. Reproduce
      # that by passing the fixture models plus their generated join models.
      let(:models) do
        [
          SchemaGeneratorHabtmFixtures::Post,
          SchemaGeneratorHabtmFixtures::Tag,
          SchemaGeneratorHabtmFixtures::PostTag,
        ] + SchemaGeneratorHabtmFixtures.join_models
      end

      let(:tables) { described_class.new(models: models, output_dir: output_dir).build_tables }
      let(:posts_tags) { tables.find { |t| t.name == "posts_tags" } }

      it "sweeps the anonymous HABTM join models into the table list" do
        # Sanity check: the join models really are treated as concrete models
        # on the join table (this is the entry point for the bug).
        join = SchemaGeneratorHabtmFixtures.join_models
        expect(join.map(&:name)).to include("HABTM_Posts", "HABTM_Tags")
        expect(join.map(&:table_name).uniq).to eq(["posts_tags"])
        expect(join.map(&:table_exists?).uniq).to eq([true])
      end

      it "emits the real join-table foreign keys, not the synthetic `left_side_id`" do
        foreign_keys = posts_tags.belongs_tos.map(&:foreign_key)

        # The synthetic `left_side_id` derived from the HABTM `belongs_to
        # :left_side` reflection must not leak into the config — no such column
        # exists in `posts_tags`.
        expect(foreign_keys).not_to include("left_side_id"),
          "schema_generate leaked the synthetic `left_side_id` foreign key " \
          "from the Rails HABTM join model: #{foreign_keys.inspect}"

        # Only the join table's true foreign keys remain.
        expect(foreign_keys).to contain_exactly("post_id", "tag_id")
      end
    end
  end
end
