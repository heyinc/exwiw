# frozen_string_literal: true

require "tmpdir"

module Exwiw
  # Run a fixed number of independent "part jobs" across forked worker processes,
  # concatenate their output parts into one IO in job order, and return each
  # job's sidecar value (whatever it hands back to the parent) in job order.
  #
  # This is the fork-orchestration foundation for the CURSOR-PARALLEL MongoDB
  # dump. Where {ParallelSerializer} forks workers that serialize contiguous
  # slices of an in-memory array the PARENT already holds, ForkedPartWriter forks
  # workers that each do their OWN work — for the dump, each opens its own Mongo
  # connection and fetches+masks+serializes a disjoint `_id` range (see
  # {MongoIdPartitioner}) — and additionally hands a sidecar value back to the
  # parent (for the dump, that range's captured FK-propagation keys, see
  # {PropagationCapture}). That distinction is the whole point: parallelizing the
  # cursor fetch — not just serialization — is what splits the serial BSON->Ruby
  # decode floor the live probe (script/bench_mongodb_cursor_parallel_probe.rb)
  # measured as ~40% of the dump, delivering a byte-identical ~3.4x@4 / ~5.5x@8
  # versus the serialization-only path's ~1.0-1.2x.
  #
  # Byte-identity contract: the parent inserts exactly one `separator` between
  # consecutive parts and nothing else, so the concatenation equals a single
  # serial stream IFF each job writes its part with NO leading or trailing
  # separator (i.e. its own records are internally `separator`-joined). Combined
  # with {MongoIdPartitioner}'s contiguous/disjoint/exhaustive/ordered ranges,
  # the parallel output is byte-for-byte identical to one serial sorted cursor.
  #
  # Sidecars cross the fork via Marshal, so a job's return value must be
  # Marshal-able (BSON::ObjectId / Integer / String propagation values are; see
  # {PropagationCapture}). The serial fallback runs jobs in-process and returns
  # their values directly — there is no process boundary to cross.
  #
  # Fallbacks (serial path, identical bytes and sidecars):
  #   - the platform has no usable fork (Windows, JRuby)
  #   - count <= 1 (forking a single job is pure overhead)
  #
  # On the fork path each job's block runs in its own process, so any global
  # state it touches (open connections, mutated objects) is confined to that
  # worker and never observed by the parent.
  module ForkedPartWriter
    module_function

    # Run `count` jobs, calling `block.call(index, part_io)` once per `index` in
    # `0...count`. The block writes that job's bytes to `part_io` (a writable IO
    # for its part) and returns its sidecar value. The parent concatenates the
    # parts into `io` in index order — inserting one `separator` between
    # consecutive parts — and returns the array of sidecar values in index order.
    #
    # `io` must be a real IO backed by a file descriptor on the fork path (the
    # parent streams the workers' part files into it via IO.copy_stream); a
    # StringIO works only on the serial path.
    def write(io, count, separator: "\n", &block)
      raise ArgumentError, "block required" unless block
      raise ArgumentError, "count must be >= 0, got #{count.inspect}" if count.negative?
      return [] if count.zero?

      if count > 1 && fork_capable?
        run_forked(io, count, separator, &block)
      else
        run_serial(io, count, separator, &block)
      end
    end

    # True when this Ruby can fork into independent processes (MRI on Unix);
    # JRuby and Windows cannot. Mirrors {ParallelSerializer.fork_capable?}.
    def fork_capable?
      Process.respond_to?(:fork) && Process.respond_to?(:waitpid)
    end

    # Run each job in-process, writing its part straight to `io` with one
    # `separator` before every part but the first — byte-identical to the fork
    # path's concat, without the part-file round trip. A job that raises
    # propagates directly (no WorkerError wrapping), matching the serial behavior
    # of {ParallelSerializer}.
    private_class_method def self.run_serial(io, count, separator, &block)
      (0...count).map do |index|
        io.write(separator) unless index.zero?
        block.call(index, io)
      end
    end

    # Fork one worker per job; each writes its part file and Marshal-dumps its
    # sidecar to a state file. The parent waits for all of them, surfaces any
    # failure, then concatenates the parts in order and loads the sidecars.
    private_class_method def self.run_forked(io, count, separator, &block)
      Dir.mktmpdir("exwiw_forked_part") do |tmpdir|
        jobs = (0...count).map do |index|
          part  = File.join(tmpdir, "part_#{index}")
          state = File.join(tmpdir, "state_#{index}")
          err   = File.join(tmpdir, "err_#{index}")
          pid = fork_worker(index, part, state, err, &block)
          [pid, part, state, err]
        end

        wait_all!(jobs)
        concat_parts!(io, jobs.map { |(_pid, part, _state, _err)| part }, separator)
        jobs.map { |(_pid, _part, state, _err)| Marshal.load(File.binread(state)) }
      end
    end

    # On any error the worker records the message in `err` and exits non-zero so
    # the parent surfaces a real failure instead of silently emitting a truncated
    # part. `exit!` skips at_exit/finalizers (test hooks, GC sweeps) that must run
    # once, in the parent only.
    private_class_method def self.fork_worker(index, part, state, err, &block)
      fork do
        begin
          sidecar = File.open(part, "w") { |f| block.call(index, f) }
          File.binwrite(state, Marshal.dump(sidecar))
          exit!(0)
        rescue Exception => e
          # Rescue Exception (not just StandardError) so the parent always gets a
          # diagnostic rather than a bare non-zero exit.
          File.write(err, "#{e.class}: #{e.message}") rescue nil
          exit!(1)
        end
      end
    end

    private_class_method def self.wait_all!(jobs)
      failures = []
      jobs.each do |(pid, _part, _state, err)|
        Process.waitpid(pid)
        next if $?.success?

        detail = (File.read(err) if File.exist?(err)) || "exit status #{$?.exitstatus.inspect}"
        failures << "worker #{pid}: #{detail}"
      end
      return if failures.empty?

      raise WorkerError, "forked part write failed (#{failures.size} worker(s)): #{failures.join('; ')}"
    end

    # Stream each part into `io` in order, inserting one `separator` between
    # consecutive parts so the result equals a serial stream across part
    # boundaries. Every index `0...count` produced a part (even one whose job
    # wrote zero bytes), so each part takes its boundary separator; skipping a
    # zero-byte part would drop a separator and diverge from the serial path.
    private_class_method def self.concat_parts!(io, parts, separator)
      parts.each_with_index do |part, i|
        io.write(separator) unless i.zero?
        File.open(part, "r") { |f| IO.copy_stream(f, io) }
      end
    end

    class WorkerError < StandardError; end
  end
end
