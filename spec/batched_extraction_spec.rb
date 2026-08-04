# frozen_string_literal: true

RSpec.describe Exwiw::BatchedExtraction do
  # Canned rows keyed off the query's FROM, so the batching is observable without
  # a database (the sqlite/postgresql e2e scenarios cover a real server).
  class RecordingAdapter
    Result = Struct.new(:rows) do
      include Enumerable

      def each(&block)
        rows.each(&block)
        self
      end

      def size
        rows.size
      end
    end

    attr_reader :executed

    def initialize(customer_ids:)
      @customer_ids = customer_ids
      @executed = []
    end

    def execute(query_ast)
      @executed << query_ast
      Result.new(rows_for(query_ast))
    end

    def self.batch_ids(query_ast)
      query_ast.join_clauses.last.where_clauses.first.value
    end

    private def rows_for(query_ast)
      return @customer_ids.map { |id| [id] } if query_ast.from_table_name == 'customers'

      # Two per customer, so a batch returns more rows than it has ids.
      self.class.batch_ids(query_ast).flat_map { |id| [["a#{id}", id], ["b#{id}", id]] }
    end
  end

  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:dump_target) { Exwiw::DumpTarget.new(ids: ['t1'], scope_column: 'tenant_id') }

  let(:customers) do
    Exwiw::TableConfig.from_symbol_keys(
      name: 'customers', primary_key: 'id', belongs_tos: [],
      columns: [{ name: 'id' }, { name: 'tenant_id' }]
    )
  end
  # Reaches the scope through customers, so customers' in-scope ids slice it.
  let(:activities) do
    Exwiw::TableConfig.from_symbol_keys(
      name: 'activities', primary_key: 'id',
      batch_scope: { table: 'customers', size: 2 },
      belongs_tos: [{ table_name: 'customers', foreign_key: 'customer_id' }],
      columns: [{ name: 'id' }, { name: 'customer_id' }]
    )
  end
  let(:all_tables) { [customers, activities] }
  let(:table_by_name) { all_tables.each_with_object({}) { |t, h| h[t.name] = t } }

  let(:customer_ids) { %w[1 2 3] }
  let(:adapter) { RecordingAdapter.new(customer_ids: customer_ids) }

  def batched(table = activities)
    described_class.build(
      adapter: adapter, table: table, dump_target: dump_target,
      table_by_name: table_by_name, logger: logger
    )
  end

  it 'is nil for a table that is not configured for batching' do
    expect(batched(customers)).to be_nil
  end

  it 'resolves the batch table and its size' do
    expect(batched.terminus.name).to eq('customers')
    expect(batched.batch_size).to eq(2)
  end

  it 'slices the extraction by the batch table in-scope primary keys' do
    extraction = batched
    expect(extraction.key_ids).to eq(%w[1 2 3])
    expect(extraction.batch_count).to eq(2)

    key_query = extraction.key_query_ast
    expect(key_query.from_table_name).to eq('customers')
    expect(key_query.columns.map(&:name)).to eq(['id'])
    expect(key_query.where_clauses.map(&:to_h)).to eq([
      { column_name: 'tenant_id', operator: :eq, value: ['t1'] },
    ])
  end

  it 'streams every batch rows as one sequence' do
    rows = batched.to_a

    expect(rows).to eq([
      ['a1', '1'], ['b1', '1'], ['a2', '2'], ['b2', '2'],
      ['a3', '3'], ['b3', '3'],
    ])
  end

  it 'partitions the ids across the batches, each covered exactly once' do
    extraction = batched
    extraction.each { |_row| nil }

    batch_queries = adapter.executed.select { |ast| ast.from_table_name == 'activities' }
    expect(batch_queries.map { |ast| RecordingAdapter.batch_ids(ast) }).to eq([%w[1 2], %w[3]])
    # The id set is resolved once, not per batch.
    expect(adapter.executed.count { |ast| ast.from_table_name == 'customers' }).to eq(1)
  end

  context 'when the id-set query returns the ids in a different order' do
    let(:customer_ids) { %w[3 1 2] }

    # The id-set query has no ORDER BY, so the engine may return the ids in any
    # order; sorting fixes the batch composition, and so the dump, across runs.
    it 'slices the same batches regardless' do
      extraction = batched
      extraction.each { |_row| nil }

      batch_queries = adapter.executed.select { |ast| ast.from_table_name == 'activities' }
      expect(batch_queries.map { |ast| RecordingAdapter.batch_ids(ast) }).to eq([%w[1 2], %w[3]])
    end
  end

  it 'logs the plan up front and each batch as it completes' do
    extraction = batched
    extraction.prepare!
    extraction.each { |_row| nil }

    expect(log_output.string).to include('Extracting in 2 batch(es) of up to 2 customers.id value(s) (3 in scope)')
    expect(log_output.string).to include('Batch 1/2: 4 record(s), 4 so far')
    expect(log_output.string).to include('Batch 2/2: 2 record(s), 6 so far')
  end

  it 'reports the total row count for the COPY output format' do
    expect(batched.size).to eq(6)
  end

  context 'when the scope keeps no rows of the batch table' do
    let(:customer_ids) { [] }

    it 'extracts nothing and says so' do
      extraction = batched
      extraction.prepare!

      expect(extraction.batch_count).to eq(0)
      expect(extraction.to_a).to eq([])
      expect(adapter.executed.map(&:from_table_name)).to eq(['customers'])
      expect(log_output.string).to include('No in-scope customers ids to batch by; extracting nothing.')
    end
  end

  it 'raises on a scoping shape a batch key cannot slice' do
    activities.batch_scope = Exwiw::BatchScope.from('table' => 'ghosts')

    expect { batched }.to raise_error(ArgumentError, /which is not in the schema/)
  end
end
