# frozen_string_literal: true

require 'logger'

require 'exwiw'

require_relative 'support/table_loader'
require_relative 'support/bootstrap_databases'
require_relative 'support/ast_factory'
require_relative 'support/self_referencing_tree'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include(TableLoader)
  config.include(AstFactory)

  config.before(:suite) do
    BootstrapDatabases.run
  end
end
