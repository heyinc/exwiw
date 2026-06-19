require 'logger'
require 'mongo'

require_relative '../script/database_config'

module MongodbScenario
  module_function

  def client(database_name)
    config = database_config("mongodb")
    Mongo::Logger.logger.level = ::Logger::WARN
    Mongo::Client.new(
      ["#{config.fetch(:host)}:#{config.fetch(:port)}"],
      database: database_name,
    )
  end
end
