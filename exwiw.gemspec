# frozen_string_literal: true

require_relative "lib/exwiw/version"

Gem::Specification.new do |spec|
  spec.name = "exwiw"
  spec.version = Exwiw::VERSION
  spec.authors = ["Shia"]
  spec.email = ["rise.shia@gmail.com"]

  spec.summary = "Ruby gem that allows you to export records from a database to a dump file."
  spec.description = "Export What I Want (Exwiw) is a Ruby gem that allows you to export records from a database to a dump file."
  spec.homepage = "https://github.com/riseshia/exwiw"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/riseshia/exwiw/tree/main"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ spec/ script/ seed/ e2e/ tmp/ .git .github .rspec Gemfile Rakefile compose.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Optional native Relaxed Extended JSON encoder for the MongoDB dump path.
  # With `extensions` set, `gem install exwiw` compiles it automatically; hosts
  # that cannot compile fall back to the pure-Ruby path (see lib/exwiw/ext_json.rb).
  spec.extensions = ["ext/exwiw/ext_json/extconf.rb"]

  # Uncomment to register a new dependency of your gem
  spec.add_dependency "serdes", "~> 0.1"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
