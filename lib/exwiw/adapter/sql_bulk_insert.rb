# frozen_string_literal: true

module Exwiw
  module Adapter
    # Shared bulk-INSERT construction for the SQL adapters (mysql / postgresql /
    # sqlite). They produce the same `INSERT INTO ... VALUES (...),(...);` shape
    # and differ only in the header's identifier quoting (see #insert_header) and
    # in #escape_value, so both the in-memory builder (#to_bulk_insert) and the
    # bounded-memory streaming writer (#write_inserts) live here.
    #
    # Each including adapter must provide two private methods:
    #   - insert_header(table) -> the "INSERT INTO ... VALUES\n" prefix
    #   - escape_value(value)  -> the SQL literal for one column value
    module SqlBulkInsert
      # How many rows' tuples to build-and-flush at a time when streaming. Bounds
      # peak memory to this many tuples (plus their joined string) instead of the
      # whole table's INSERT string, while keeping each flush a single fast
      # Array#map + Array#join (the same C-level path #to_bulk_insert uses) so it
      # stays close to whole-string speed — far faster than a naive row-at-a-time
      # IO#print (see script/bench_sql_dump.rb / docs/sql-dump-optimization-notes.md).
      # Mirrors MongoDB's default chunk size: bounded work per flush, but the SQL
      # adapters still emit ONE statement (byte-identical to the un-chunked build).
      STREAM_FLUSH_ROWS = 2_000

      # Build the whole INSERT statement as a single String. Kept for callers
      # that want the string form (and as the readable definition of the exact
      # bytes #write_inserts streams).
      def to_bulk_insert(results, table)
        value_list = results.map { |row| insert_tuple(row) }
        "#{insert_header(table)}#{value_list.join(",\n")};"
      end

      # Stream the bulk INSERT(s) straight to `io` instead of materializing the
      # whole statement string first. Byte-for-byte identical to writing
      # #to_bulk_insert per chunk joined by "\n" (verified by
      # insert_output_snapshot_spec), but only one ~STREAM_FLUSH_BYTES buffer is
      # resident at a time rather than the entire table's INSERT string. Returns
      # [statement_count, record_count]; record_count is tallied during the single
      # streaming drain so the Runner needs no separate SELECT COUNT(*) pass.
      def write_inserts(io, results, table, chunk_size)
        chunks = chunk_size ? results.each_slice(chunk_size) : [results]
        statement_count = 0
        record_count = 0
        chunks.each do |chunk_rows|
          io.print("\n") if statement_count.positive?
          record_count += stream_single_insert(io, chunk_rows, table)
          statement_count += 1
        end
        [statement_count, record_count]
      end

      # Emit one `INSERT INTO ... VALUES <tuples>;` statement to `io`, building
      # and flushing the value tuples STREAM_FLUSH_ROWS at a time so the full
      # statement text is never held in memory at once. Each flush is one fast
      # map+join; the ",\n" between flushes reproduces the same separator
      # #to_bulk_insert puts between every tuple, so the bytes are identical.
      # Returns the number of rows written, tallied as the stream is drained.
      #
      # Rows are buffered off `#each` rather than `rows.each_slice(...)`:
      # each_slice queries the receiver's `#size`, which on a streaming result
      # issues a redundant `SELECT COUNT(*)` (a second full pass over the same
      # filter). Manual buffering walks the cursor exactly once.
      private def stream_single_insert(io, rows, table)
        io.print(insert_header(table))
        first = true
        record_count = 0
        buffer = []
        flush = lambda do
          io.print(",\n") unless first
          first = false
          io.print(buffer.map { |row| insert_tuple(row) }.join(",\n"))
          record_count += buffer.size
          buffer.clear
        end
        rows.each do |row|
          buffer << row
          flush.call if buffer.size >= STREAM_FLUSH_ROWS
        end
        flush.call unless buffer.empty?
        io.print(";")
        record_count
      end

      private def insert_tuple(row)
        "(" + row.map { |value| escape_value(value) }.join(', ') + ")"
      end
    end
  end
end
