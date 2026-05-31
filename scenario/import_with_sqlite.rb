require 'sqlite3'

new_db_path = ARGV.first
connection = SQLite3::Database.new(new_db_path)

Dir["tmp/sqlite/delete-*.sql"].each do |file|
  puts "Run #{file}"
  sql = File.read(file)
  connection.execute_batch(sql)
end

Dir["tmp/sqlite/insert-*.sql"].each do |file|
  puts "Run #{file}"
  sql = File.read(file)
  connection.execute_batch(sql)
end
