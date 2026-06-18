# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tempfile"

module Exwiw
  RSpec.describe ParallelSerializer do
    # Drive the fork path (workers > 1, min_batch forced to 1) and read the
    # result back from a real file — the forked workers write part files the
    # parent concatenates, so the output must be a real IO, not a StringIO.
    #
    # Datasets are deliberately small: the fork path is exercised whenever
    # workers > 1 and items.size >= min_batch, so byte-for-byte correctness
    # (ordering, separators, empty items) is fully proven with a handful of
    # items. Large-batch behavior and the actual wall-time speedup are validated
    # separately by script/bench_mongodb_parallel_probe.rb.
    def forked_output(items, workers:, separator: "\n", min_batch: 1, &block)
      Tempfile.create("ps_out") do |f|
        described_class.write(f, items, workers: workers, separator: separator, min_batch: min_batch, &block)
        f.flush
        f.rewind
        return f.read
      end
    end

    def serial_join(items, separator: "\n", &block)
      items.map(&block).join(separator)
    end

    describe ".write (fork path)" do
      to_s = ->(x) { x.to_s }

      it "is byte-identical to the serial join across counts and worker counts" do
        [[(1..6).to_a, 2], [(1..50).to_a, 4], [(1..99).to_a, 4],
         [(1..100).to_a, 8]].each do |items, workers|
          strs = items.map(&:to_s)
          expect(forked_output(strs, workers: workers, &:itself))
            .to eq(serial_join(strs, &:itself)), "count=#{items.size} workers=#{workers}"
        end
      end

      it "spawns at most one worker per item when workers exceeds the item count" do
        items = %w[a b c]
        expect(forked_output(items, workers: 8, &to_s)).to eq("a\nb\nc")
      end

      it "preserves boundary separators even when items serialize to empty strings" do
        items = ["", "x", "", "", "y", ""]
        expect(forked_output(items, workers: 6, &to_s)).to eq(items.join("\n"))
      end

      it "honors a custom separator" do
        items = (1..20).map(&:to_s)
        expect(forked_output(items, workers: 4, separator: ",", &to_s)).to eq(items.join(","))
      end

      it "handles a single item and an empty list" do
        expect(forked_output(["only"], workers: 4, &to_s)).to eq("only")
        expect(forked_output([], workers: 4, &to_s)).to eq("")
      end

      it "confines block mutations to the worker process" do
        arr = [{ "v" => 1 }, { "v" => 2 }]
        forked_output(arr, workers: 2) { |h| h["v"] *= 100; h["v"].to_s }
        expect(arr.map { |h| h["v"] }).to eq([1, 2])
      end

      it "surfaces a worker block failure as WorkerError instead of silent truncation" do
        expect do
          Tempfile.create("ps_err") do |f|
            described_class.write(f, (1..10).to_a, workers: 3, min_batch: 1) do |x|
              raise "boom-#{x}" if x == 5

              x.to_s
            end
          end
        end.to raise_error(described_class::WorkerError, /boom-5/)
      end
    end

    describe ".write (serial fallback)" do
      to_s = ->(x) { x.to_s }

      it "uses the serial path below min_batch, byte-identical to the join" do
        sio = StringIO.new
        described_class.write(sio, (1..100).map(&:to_s), workers: 4, min_batch: 2_000, &to_s)
        expect(sio.string).to eq((1..100).map(&:to_s).join("\n"))
      end

      it "uses the serial path when workers <= 1" do
        sio = StringIO.new
        described_class.write(sio, %w[a b c], workers: 1, &to_s)
        expect(sio.string).to eq("a\nb\nc")
      end

      it "uses the serial path when fork is unavailable" do
        allow(described_class).to receive(:fork_capable?).and_return(false)
        sio = StringIO.new
        described_class.write(sio, (1..5_000).map(&:to_s), workers: 8, min_batch: 1, &to_s)
        expect(sio.string).to eq((1..5_000).map(&:to_s).join("\n"))
      end

      it "raises a worker block failure directly (no WorkerError wrapping) on the serial path" do
        expect do
          described_class.write(StringIO.new, [1, 2, 3], workers: 1) do |x|
            raise "serial-boom" if x == 2

            x.to_s
          end
        end.to raise_error(RuntimeError, /serial-boom/)
      end
    end

    describe ".write argument validation" do
      it "requires a block" do
        expect { described_class.write(StringIO.new, [1, 2]) }
          .to raise_error(ArgumentError, /block required/)
      end
    end
  end
end
