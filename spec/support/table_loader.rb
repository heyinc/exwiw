# frozen_string_literal: true

module TableLoader
  private def table_repository
    @table_repository ||= Hash.new { |h, k| h[k] = {} }
  end

  %i[
    shops
    users
    products
    orders
    order_items
    transactions
    reviews
    system_announcements
    posts
  ].each do |table_name|
    define_method("#{table_name}_table") do |adapter|
      adapter = adapter.to_sym
      table = table_repository[adapter][table_name]
      return table if table

      path = File.join("scenario", "#{adapter}-schema", "#{table_name}.json")
      raise "Table config not found: #{path}" unless File.exist?(path)

      json = JSON.parse(File.read(path))
      klass =
        if adapter == :mongodb
          Exwiw::MongodbCollectionConfig
        else
          Exwiw::TableConfig
        end
      table = klass.from(json)
      table_repository[adapter][table_name] = table
    end
  end
end
