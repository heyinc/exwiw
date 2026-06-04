# frozen_string_literal: true

namespace :exwiw do
  namespace :schema do
    desc "Generate schema from application"
    task generate: :environment do
      require "exwiw"

      Exwiw::SchemaGenerator.from_rails_application(
        output_dir: ENV["OUTPUT_DIR_PATH"] || "exwiw",
      ).generate!
    end

    desc "Remove tables/columns from the schema config that no longer exist in the application"
    task tidy: :environment do
      require "exwiw"

      result = Exwiw::SchemaGenerator.from_rails_application(
        output_dir: ENV["OUTPUT_DIR_PATH"] || "exwiw",
      ).tidy!

      if result.empty?
        puts "exwiw: schema config is already tidy; nothing to remove."
      else
        result.removed_tables.each do |name|
          puts "exwiw: removed config for table '#{name}' (no longer exists in the application)."
        end
        result.removed_columns.each do |table_name, columns|
          puts "exwiw: removed column(s) #{columns.join(', ')} from '#{table_name}' (no longer in the table)."
        end
      end
    end

    desc "Generate schema from a Mongoid application"
    # Set EXWIW_SKIP_UNSUPPORTED=1 to keep generation going past constructs exwiw
    # cannot represent (an unresolvable `belongs_to`, or a polymorphic / cyclic /
    # unresolvable `embedded_in`): the unresolvable belongs_to is skipped and an
    # unrepresentable embedded collection is emitted as `ignore: true` with a
    # `comment`, each warned to stderr, instead of aborting the whole run.
    task generate_mongoid: :environment do
      require "exwiw"

      Exwiw::MongoidSchemaGenerator.from_rails_application(
        output_dir: ENV["OUTPUT_DIR_PATH"] || "exwiw",
        skip_unsupported: ENV["EXWIW_SKIP_UNSUPPORTED"] == "1",
      ).generate!
    end
  end
end
