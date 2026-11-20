# frozen_string_literal: true

# The `source:` and `schema:` a runner takes, from a connection config and a schema directory.
module RunnerInputs
  private def runner_inputs(connection_config:, schema_dir:, profiles: [], profile: nil)
    source = Exwiw::DataSource.connect(connection_config)
    schema = Exwiw::Schema.load(
      dir: schema_dir, config_class: source.adapter_class.table_config_class, profiles: profiles, profile: profile,
    )
    { source: source, schema: schema }
  end
end
