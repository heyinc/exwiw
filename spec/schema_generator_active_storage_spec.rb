# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "active_record"
require "sqlite3"

# Strategy check for ActiveStorage support.
#
# ActiveStorage stores attachments across two tables:
#   - active_storage_blobs        (the uploaded file's metadata; no belongs_to)
#   - active_storage_attachments  (a join row pointing at the blob *and* at the
#                                  owning record via a polymorphic `record`)
#
# The `has_one_attached` / `has_many_attached` macros do NOT add a column to the
# owning model. Instead they generate ordinary associations:
#
#   has_one_attached :avatar  ==>
#     has_one  :avatar_attachment, class_name: "ActiveStorage::Attachment", as: :record
#     has_one  :avatar_blob, through: :avatar_attachment, source: :blob
#
#   has_many_attached :photos ==>
#     has_many :photos_attachments, class_name: "ActiveStorage::Attachment", as: :record
#     has_many :photos_blobs, through: :photos_attachments, source: :blob
#
# and `ActiveStorage::Attachment` declares:
#
#     belongs_to :record, polymorphic: true
#     belongs_to :blob,   class_name: "ActiveStorage::Blob"
#
# So the existing polymorphic-`belongs_to` machinery already models the
# *attachments* side correctly *without any ActiveStorage-specific code*:
#   - the `record` polymorphic belongs_to expands to one entry per model that
#     declared `has_one_attached` / `has_many_attached` (found via the generated
#     `has_* ..., as: :record` reflections), letting exwiw extract only the
#     attachments whose record is one of the dumped rows;
#   - the `blob` belongs_to correctly records active_storage_attachments ->
#     active_storage_blobs as a foreign key, which keeps blobs ordered before
#     attachments at insert time.
#
# The *blobs* side needs more than schema generation. exwiw only propagates
# downward along belongs_to: it extracts a table by finding a belongs_to path
# FROM that table TO the dump target (QueryAstBuilder#find_path_to_dump_target).
# active_storage_blobs has no belongs_to at all, so it has no path to the target
# and would fall into the "no relation -> dump all records" branch. That gap is
# now closed at dump time by QueryAstBuilder's reverse/"referenced_by" mechanism
# (blobs WHERE id IN (SELECT blob_id FROM <extracted attachments>)); see
# query_ast_builder_spec.rb's "referenced by an extractable child" contexts.
#
# These specs therefore lock in the schema-generation half (the belongs_tos that
# following the macros yields); the reverse-extraction half is covered in
# query_ast_builder_spec.rb. The fixtures replicate exactly what the macros
# generate (the gem itself is not a dependency), mirroring the approach in
# schema_generator_habtm_spec.rb.
module Exwiw
  module ActiveStorageFixtures
    # ActiveStorage::Blob — has no belongs_to; attachments point *at* it.
    class AsBlob < ::ActiveRecord::Base
      self.table_name = "active_storage_blobs"
      has_many :attachments,
               class_name: "Exwiw::ActiveStorageFixtures::AsAttachment",
               foreign_key: :blob_id
    end

    # ActiveStorage::Attachment — the polymorphic join row.
    class AsAttachment < ::ActiveRecord::Base
      self.table_name = "active_storage_attachments"
      belongs_to :record, polymorphic: true
      belongs_to :blob, class_name: "Exwiw::ActiveStorageFixtures::AsBlob"
    end

    # `has_one_attached :avatar` expands to these two associations.
    class User < ::ActiveRecord::Base
      self.table_name = "as_users"
      has_one :avatar_attachment,
              -> { where(name: "avatar") },
              class_name: "Exwiw::ActiveStorageFixtures::AsAttachment",
              as: :record,
              inverse_of: :record
      has_one :avatar_blob,
              through: :avatar_attachment,
              class_name: "Exwiw::ActiveStorageFixtures::AsBlob",
              source: :blob
    end

    # `has_many_attached :photos` expands to these two associations.
    class Product < ::ActiveRecord::Base
      self.table_name = "as_products"
      has_many :photos_attachments,
               -> { where(name: "photos") },
               class_name: "Exwiw::ActiveStorageFixtures::AsAttachment",
               as: :record,
               inverse_of: :record
      has_many :photos_blobs,
               through: :photos_attachments,
               class_name: "Exwiw::ActiveStorageFixtures::AsBlob",
               source: :blob
    end
  end

  RSpec.describe SchemaGenerator do
    describe "ActiveStorage (has_one_attached / has_many_attached) handling" do
      before(:all) do
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
        conn = ActiveRecord::Base.connection
        conn.create_table(:active_storage_blobs) do |t|
          t.string :key, null: false
          t.string :filename, null: false
          t.string :content_type
          t.bigint :byte_size, null: false
          t.string :checksum
          t.datetime :created_at, null: false
        end
        conn.create_table(:active_storage_attachments) do |t|
          t.string :name, null: false
          t.string :record_type, null: false
          t.bigint :record_id, null: false
          t.bigint :blob_id, null: false
          t.datetime :created_at, null: false
        end
        conn.create_table(:as_users) { |t| t.string :name }
        conn.create_table(:as_products) { |t| t.string :name }
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

      let(:models) do
        [
          ActiveStorageFixtures::AsBlob,
          ActiveStorageFixtures::AsAttachment,
          ActiveStorageFixtures::User,
          ActiveStorageFixtures::Product,
        ]
      end

      let(:tables) { described_class.new(models: models, output_dir: output_dir).build_tables }
      let(:tables_by_name) { tables.each_with_object({}) { |t, h| h[t.name] = t } }

      it "covers both ActiveStorage tables plus the owning models" do
        expect(tables_by_name.keys).to include(
          "active_storage_blobs", "active_storage_attachments", "as_users", "as_products",
        )
      end

      it "emits no belongs_to on active_storage_blobs (it is the parent table)" do
        expect(tables_by_name["active_storage_blobs"].belongs_tos).to be_empty
      end

      it "keeps the non-polymorphic blob foreign key on active_storage_attachments" do
        non_poly = tables_by_name["active_storage_attachments"].belongs_tos
          .reject(&:polymorphic?)
          .map { |b| [b.table_name, b.foreign_key] }

        expect(non_poly).to contain_exactly(["active_storage_blobs", "blob_id"])
      end

      it "expands the polymorphic `record` into one belongs_to per attached model" do
        poly = tables_by_name["active_storage_attachments"].belongs_tos
          .select(&:polymorphic?)
          .map { |b| [b.table_name, b.foreign_key, b.foreign_type, b.type_value] }

        # Both User (has_one_attached) and Product (has_many_attached) declared a
        # `has_* ..., as: :record` association, so the polymorphic `record`
        # belongs_to expands to one entry each, carrying the record_type filter.
        expect(poly).to contain_exactly(
          ["as_users", "record_id", "record_type", ActiveStorageFixtures::User.polymorphic_name],
          ["as_products", "record_id", "record_type", ActiveStorageFixtures::Product.polymorphic_name],
        )
      end

      it "does not leak the macro-generated `through` blob associations as belongs_tos" do
        # `avatar_blob` / `photos_blobs` are `has_* through:` reflections on the
        # owning models, not belongs_tos, so they must not appear on as_users /
        # as_products configs.
        expect(tables_by_name["as_users"].belongs_tos).to be_empty
        expect(tables_by_name["as_products"].belongs_tos).to be_empty
      end
    end
  end
end
