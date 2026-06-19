# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rake/extensiontask"

require "exwiw"

path = File.expand_path(__dir__)
Dir.glob("#{path}/lib/tasks/**/*.rake").each { |f| import f }

# Build the native Extended-JSON encoder into lib/exwiw/ext_json_native.{so,bundle}.
Rake::ExtensionTask.new("ext_json_native") do |ext|
  ext.ext_dir = "ext/exwiw/ext_json"
  ext.lib_dir = "lib/exwiw"
end

RSpec::Core::RakeTask.new(:spec)

# Specs include a byte-identity guard for the native encoder; compile first so it
# is exercised rather than silently falling back to pure Ruby.
task spec: :compile

task default: :spec
