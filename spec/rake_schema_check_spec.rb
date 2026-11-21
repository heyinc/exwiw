# frozen_string_literal: true

require "spec_helper"
require "rake"
require "tmpdir"
require "active_record"
require "sqlite3"

require_relative "../script/database_config"

module Exwiw
  RSpec.describe "rake exwiw:schema:check" do
    before(:all) do
      # Absolute, as the examples run in another directory.
      config = database_config(:sqlite)
      ActiveRecord::Base.establish_connection(config.merge(database: File.expand_path(config[:database])))
      require_relative "../script/models"
    end

    after(:all) do
      ActiveRecord::Base.remove_connection
    end

    around do |example|
      original = Rake.application
      Rake.application = Rake::Application.new
      Rake::Task.define_task(:environment)
      load File.expand_path("../lib/tasks/exwiw.rake", __dir__)
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { example.run }
      end
    ensure
      Rake.application = original
    end

    # The task reads the models of a Rails application, which there is none of here.
    before do
      allow(SchemaCheck).to receive(:from_rails_application) { |**options| SchemaCheck.new(models: [User], **options) }
      SchemaGenerator.new(models: [User], output_dir: "exwiw/schema", safe_new_columns: false).generate!
    end

    def run_task
      Rake::Task["exwiw:schema:check"].invoke
    end

    it "runs the checks the config file enables, and says regenerating does not fix them" do
      File.write("exwiw.yml", "check:\n  unmasked_sensitive: true\n")

      expect do
        expect { run_task }.to output(/"unmasked_sensitive": \[\s*"users.email \[base\]: looks sensitive/).to_stdout
      end.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output(/the unmasked_sensitive check\(s\) found problems in the config, which regenerating does not fix/).to_stderr
    end

    it "runs integrity alone without a check section" do
      expect { run_task }.to output(/"integrity": \[\]/).to_stdout
    end

    it "fails on an invalid check section" do
      File.write("exwiw.yml", "check:\n  unmasked_sensitive:\n    profiles: [dev]\n")

      expect { run_task }.to raise_error(ArgumentError, /'check.unmasked_sensitive.profiles' names undeclared profile\(s\) dev/)
    end
  end
end
