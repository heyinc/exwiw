# frozen_string_literal: true

module Exwiw
  # Where a runner reads: how to connect, or a driver connection (and, for MongoDB, a session) the caller already
  # holds and keeps owning.
  DataSource = Data.define(:connection_config, :connection, :session) do
    # @param connection_config [Exwiw::ConnectionConfig] how to connect
    # @return [Exwiw::DataSource]
    def self.connect(connection_config)
      new(connection_config: connection_config, connection: nil, session: nil)
    end

    # @param adapter_name [String] the exwiw adapter (or an alias, e.g. ActiveRecord's adapter_name)
    # @param connection [Object] see Exwiw::Adapter::Base#initialize for the accepted driver connections
    # @param session [Mongo::Session, nil] mongodb only: the caller's session (e.g. a transaction's) to read in
    # @return [Exwiw::DataSource]
    def self.given(adapter_name, connection, session: nil)
      new(connection_config: ConnectionConfig.new(adapter: adapter_name), connection: connection, session: session)
    end

    # @return [Class] the adapter class, without connecting to anything
    def adapter_class
      Adapter.class_for(connection_config.adapter)
    end

    # @param logger [Logger]
    # @return [Exwiw::Adapter::Base] a new adapter; adapters keep per-run state, so build one per run
    def build_adapter(logger)
      Adapter.build(connection_config, logger, connection: connection, session: session)
    end

    # @return [Boolean] whether the caller holds the connection, so it cannot be reopened (e.g. in a forked worker)
    def given_connection?
      !connection.nil?
    end
  end
end
