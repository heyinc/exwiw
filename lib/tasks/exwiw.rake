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

    desc "Generate schema from a Mongoid application"
    task generate_mongoid: :environment do
      require "exwiw"

      Exwiw::MongoidSchemaGenerator.from_rails_application(
        output_dir: ENV["OUTPUT_DIR_PATH"] || "exwiw",
      ).generate!
    end
  end
end
