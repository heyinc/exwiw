require "spec_helper"
require "fileutils"
require "tmpdir"

module Exwiw
  # End-to-end check: force the MySQL adapter onto the trilogy driver, run a full
  # export, and assert the generated insert-* files match the committed mysql
  # snapshot (which was produced with the mysql2 driver). This proves the dump is
  # the same regardless of which MySQL driver exwiw connected through.
  #
  # The only normalized difference is trailing-zero formatting inside quoted
  # numeric / datetime literals: mysql2's `cast: false` echoes the raw column text
  # (`'30.00'`, `'...00:00:00.000000'`), while trilogy casts to BigDecimal / Time
  # and we re-stringify, dropping insignificant trailing zeros (`'30.0'`,
  # `'...00:00:00'`). Both re-insert to the same value. The normalization is
  # applied to BOTH sides, so it can only hide that specific formatting gap — a
  # genuine data difference would still fail the comparison.
  RSpec.describe "exporting MySQL via the trilogy driver" do
    snapshot_dir = "spec/insert_output_snapshots/mysql"

    def canonicalize(sql)
      sql.gsub(/(\d+)\.(\d+)'/) do
        int = Regexp.last_match(1)
        frac = Regexp.last_match(2).sub(/0+\z/, "")
        frac.empty? ? "#{int}'" : "#{int}.#{frac}'"
      end
    end

    let(:connection_config) do
      ConnectionConfig.new(
        adapter: "mysql",
        database_name: "exwiw_test",
        host: "127.0.0.1", port: 3306,
        user: "root", password: "rootpassword",
      )
    end

    around do |ex|
      Dir.mktmpdir do |dir|
        @output_dir = dir
        ex.run
      end
    end

    it "produces the same insert-* output as the mysql2 driver" do
      allow(Adapter::MysqlClient).to receive(:detect_driver).and_return(:trilogy)

      # Guard: the stub must actually force trilogy (building a client is lazy and
      # does not open a connection), otherwise this test would silently re-run the
      # mysql2 path and prove nothing.
      expect(Adapter::MysqlClient.new(connection_config).driver).to eq(:trilogy)

      runner = Runner.new(
        connection_config: connection_config,
        output_dir: @output_dir,
        config_dir: "scenario/mysql-schema",
        dump_target: DumpTarget.new(table_name: "shops", ids: ["1"]),
        output_format: "insert",
        logger: ::Logger.new(nil),
      )
      runner.run

      actual_paths = Dir[File.join(@output_dir, "insert-*")].sort
      snapshot_paths = Dir[File.join(snapshot_dir, "insert-*")].sort

      expect(actual_paths.map { |p| File.basename(p) })
        .to eq(snapshot_paths.map { |p| File.basename(p) })

      snapshot_paths.each do |snapshot_path|
        basename = File.basename(snapshot_path)
        actual = canonicalize(File.read(File.join(@output_dir, basename)))
        expected = canonicalize(File.read(snapshot_path))
        expect(actual).to eq(expected), "trilogy export differs from the mysql snapshot in #{basename}"
      end
    end
  end
end
