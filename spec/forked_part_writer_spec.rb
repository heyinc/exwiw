# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tempfile"
require "bson"

module Exwiw
  RSpec.describe ForkedPartWriter do
    # Drive the fork path (count > 1) and read the concatenation back from a real
    # file — the forked workers write part files the parent concatenates, so the
    # output must be a real IO, not a StringIO. Returns [bytes, sidecars].
    #
    # Datasets are deliberately tiny: the fork path is exercised for any count >
    # 1, so byte-for-byte correctness (ordering, separators, zero-byte parts) and
    # sidecar transport are fully proven with a handful of jobs. Keeping them tiny
    # also keeps the concurrent-write window microscopic, avoiding the
    # fork-under-RSpec IO-flush flakiness larger datasets can trigger. The actual
    # wall-time speedup is validated separately by
    # script/bench_mongodb_cursor_parallel_probe.rb on live mongo.
    def forked(count, separator: "\n", &block)
      Tempfile.create("fpw_out") do |f|
        sidecars = described_class.write(f, count, separator: separator, &block)
        f.flush
        f.rewind
        return [f.read, sidecars]
      end
    end

    describe ".write (fork path)" do
      it "writes each job's part in index order and returns sidecars in index order" do
        out, sidecars = forked(4) do |index, part_io|
          part_io.write("job#{index}")
          index * 10
        end

        expect(out).to eq("job0\njob1\njob2\njob3")
        expect(sidecars).to eq([0, 10, 20, 30])
      end

      it "lets a job write its own records, internally separator-joined, with no boundary surprises" do
        # A job streaming N records writes them itself (separator between, none
        # leading/trailing); the parent only joins parts. The bytes must equal one
        # flat separator-joined stream of every record across all parts.
        records_per_job = [%w[a b], %w[c], %w[d e f]]
        out, _ = forked(3) do |index, part_io|
          records_per_job[index].each_with_index do |rec, i|
            part_io.write("\n") unless i.zero?
            part_io.write(rec)
          end
          nil
        end

        expect(out).to eq(records_per_job.flatten.join("\n"))
      end

      it "preserves boundary separators even when a job writes zero bytes" do
        parts = ["x", "", "x", ""]
        out, _ = forked(4) do |index, part_io|
          part_io.write(parts[index])
          nil
        end

        expect(out).to eq(parts.join("\n"))
      end

      it "honors a custom separator" do
        out, _ = forked(3, separator: ",") do |index, part_io|
          part_io.write(index.to_s)
          nil
        end

        expect(out).to eq("0,1,2")
      end

      it "Marshal-ships rich sidecar values (incl. BSON::ObjectId) back from each worker" do
        # ObjectIds captured in a real dump come from `doc[key]` — decoded from
        # BSON, so their bytes are concrete. A freshly-`new`'d ObjectId is instead
        # lazily generated and would materialize to a DIFFERENT value in each
        # forked child; `.to_s` here fixes the value in the parent before fork,
        # matching the production (already-materialized) case.
        oids = Array.new(3) { BSON::ObjectId.new }
        oids.each(&:to_s)
        out, sidecars = forked(3) do |index, part_io|
          part_io.write("d#{index}")
          { "_id" => [oids[index]], "n" => index }
        end

        expect(out).to eq("d0\nd1\nd2")
        expect(sidecars).to eq([
          { "_id" => [oids[0]], "n" => 0 },
          { "_id" => [oids[1]], "n" => 1 },
          { "_id" => [oids[2]], "n" => 2 },
        ])
        expect(sidecars.first["_id"].first).to be_a(BSON::ObjectId)
      end

      it "confines block side effects to the worker process" do
        shared = []
        forked(2) do |index, part_io|
          part_io.write("x")
          shared << index
          nil
        end

        expect(shared).to be_empty
      end

      it "surfaces a worker failure as WorkerError instead of silent truncation" do
        expect do
          forked(3) do |index, part_io|
            raise "boom-#{index}" if index == 1

            part_io.write("x")
            nil
          end
        end.to raise_error(described_class::WorkerError, /boom-1/)
      end
    end

    describe ".write (serial fallback)" do
      it "uses the serial path for a single job, byte-identical with its sidecar" do
        sio = StringIO.new
        sidecars = described_class.write(sio, 1) do |index, part_io|
          part_io.write("only")
          index + 100
        end

        expect(sio.string).to eq("only")
        expect(sidecars).to eq([100])
      end

      it "uses the serial path when fork is unavailable, byte- and sidecar-identical to the fork path" do
        block = ->(index, io) { io.write("doc-#{index}-payload"); { "n" => index } }

        fork_out, fork_sidecars = forked(5, &block)

        allow(described_class).to receive(:fork_capable?).and_return(false)
        sio = StringIO.new
        serial_sidecars = described_class.write(sio, 5, &block)

        expect(sio.string).to eq(fork_out)
        expect(serial_sidecars).to eq(fork_sidecars)
      end

      it "raises a job failure directly (no WorkerError wrapping) on the serial path" do
        expect do
          described_class.write(StringIO.new, 1) do |_index, _io|
            raise "serial-boom"
          end
        end.to raise_error(RuntimeError, /serial-boom/)
      end
    end

    describe ".write argument validation" do
      it "requires a block" do
        expect { described_class.write(StringIO.new, 2) }
          .to raise_error(ArgumentError, /block required/)
      end

      it "rejects a negative count" do
        expect { described_class.write(StringIO.new, -1) { |_i, _io| } }
          .to raise_error(ArgumentError, /count must be >= 0/)
      end

      it "writes nothing and returns no sidecars for a zero count" do
        out, sidecars = forked(0) { |index, part_io| part_io.write("x"); index }
        expect(out).to eq("")
        expect(sidecars).to eq([])
      end
    end
  end
end
