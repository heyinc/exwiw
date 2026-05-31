#!/bin/bash

## SQLite

export DATABASE_NAME="tmp/seed.sqlite3"
rm -f "${DATABASE_NAME}"

bundle exec ruby script/define_schema.rb "sqlite"
sqlite3 tmp/seed.sqlite3 ".schema" > seed/sqlite-schema.sql
bundle exec ruby script/generate_data.rb "sqlite"
sqlite3 tmp/seed.sqlite3 ".dump" > seed/sqlite-dump.sql

## MySQL

export DATABASE_NAME="exwiw_seed"

docker compose exec -e MYSQL_PWD=rootpassword mysql mysql -u root -e "DROP DATABASE IF EXISTS ${DATABASE_NAME}; CREATE DATABASE ${DATABASE_NAME};"

bundle exec ruby script/define_schema.rb "mysql"
docker compose exec -e MYSQL_PWD=rootpassword mysql mysqldump -u root \
  --no-data "${DATABASE_NAME}" > seed/mysql-schema.sql
bundle exec ruby script/generate_data.rb "mysql"
docker compose exec -e MYSQL_PWD=rootpassword mysql mysqldump -u root \
 "${DATABASE_NAME}" > seed/mysql-dump.sql

## PostgreSQL

export DATABASE_NAME="exwiw_seed"

docker compose exec postgres psql -U postgres -c "DROP DATABASE IF EXISTS ${DATABASE_NAME}"
docker compose exec postgres psql -U postgres -c "CREATE DATABASE ${DATABASE_NAME}"

bundle exec ruby script/define_schema.rb "postgresql"
docker compose exec postgres pg_dump -U postgres -d "${DATABASE_NAME}" --schema-only > seed/postgresql-schema.sql

bundle exec ruby script/generate_data.rb "postgresql"
docker compose exec postgres pg_dump -U postgres -d "${DATABASE_NAME}" > seed/postgresql-dump.sql
