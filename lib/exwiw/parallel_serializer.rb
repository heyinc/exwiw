# frozen_string_literal: true

require "tmpdir"

module Exwiw
  # Serialize a list of items to an IO across forked worker processes, in the
  # original order, byte-for-byte identical to a serial `items.map(&block).join(separator)`.
  #
  # Why fork (and not threads): for the MongoDB dump the per-document cost is
  # dominated by `as_extended_json` + `JSON.generate`, both pure Ruby. They hold
  # the GVL, so threads give no speedup; only separate processes use multiple
  # cores. A DB-free probe (script/bench_mongodb_parallel_probe.rb) measured a
  # byte-identical ~2x wall-time win at 4–8 workers, which this component makes
  # reusable production code.
  #
  # Mechanics: the items array is split into `workers` contiguous slices. Each
  # worker fork COW-inherits the array and serializes only its slice to its own
  # part file; the parent waits for all workers, then concatenates the part files
  # into `io` in slice order. Because every slice is serialized with the same
  # `separator` and the parent re-inserts one `separator` between consecutive
  # non-empty parts, the concatenation is exactly the serial join.
  #
  # Fallbacks (serial path, identical bytes):
  #   - the platform has no usable fork (Windows, JRuby)
  #   - workers <= 1
  #   - fewer than `min_batch` items (fork/part-file/concat overhead would not
  #     amortize on a small batch; the probe needed multi-thousand-doc batches to
  #     win)
  #
  # The block runs in the worker process, so any mutation it performs on an item
  # (e.g. in-place masking) is confined to that worker's address space and never
  # observed by the parent — callers must not rely on such side effects.
  module ParallelSerializer
    module_function

    # Default batch size below which forking is skipped. The probe showed fork
    # overhead only amortizes on batches in the thousands; below that the serial
    # path is as fast and far simpler.
    DEFAULT_MIN_BATCH = 2_000

    # Write `items.map(&block).join(separator)` to `io`, using up to `workers`
    # forked processes when it is worthwhile. Returns the number of items written.
    #
    # `io` must be a real IO backed by a file descriptor (the parent streams the
    # workers' part files into it via IO.copy_stream); a StringIO works only on
    # the serial path.
    def write(io, items, workers: 1, separator: "\n", min_batch: DEFAULT_MIN_BATCH, &block)
      raise ArgumentError, "block required" unless block

      if workers <= 1 || items.size < min_batch || !fork_capable?
        return write_serial(io, items, separator, &block)
      end

      write_forked(io, items, workers, separator, &block)
    end

    # True when this Ruby can fork into independent processes. MRI on Unix can;
    # JRuby and Windows cannot (Process.fork is absent or raises NotImplementedError).
    def fork_capable?
      Process.respond_to?(:fork) && Process.respond_to?(:waitpid)
    end

    private_class_method def self.write_serial(io, items, separator, &block)
      first = true
      items.each do |item|
        io.write(separator) unless first
        io.write(block.call(item))
        first = false
      end
      items.size
    end

    private_class_method def self.write_forked(io, items, workers, separator, &block)
      slice_size = (items.size / workers.to_f).ceil

      Dir.mktmpdir("exwiw_parallel") do |tmpdir|
        # Slices are launched in order; each non-empty slice gets one worker that
        # writes its part file. (slice_index, pid, part_path, err_path) is kept so
        # the parent can wait, check status, and concatenate in order.
        jobs = []
        index = 0
        while (lo = index * slice_size) < items.size
          hi = [lo + slice_size, items.size].min
          part = File.join(tmpdir, "part_#{index}")
          err = File.join(tmpdir, "err_#{index}")
          pid = fork_worker(items, lo, hi, part, err, separator, &block)
          jobs << [pid, part, err]
          index += 1
        end

        wait_all!(jobs)
        concat_parts!(io, jobs.map { |(_pid, part, _err)| part }, separator)
      end

      items.size
    end

    # Fork one worker that serializes items[lo...hi] into `part`. On any error it
    # records the message in `err` and exits non-zero so the parent can surface a
    # real failure instead of silently emitting a truncated part. `exit!` skips
    # at_exit/finalizers (test framework hooks, GC sweeps) that must run once, in
    # the parent only.
    private_class_method def self.fork_worker(items, lo, hi, part, err, separator, &block)
      fork do
        begin
          File.open(part, "w") do |f|
            first = true
            (lo...hi).each do |i|
              f.write(separator) unless first
              f.write(block.call(items[i]))
              first = false
            end
          end
          exit!(0)
        rescue Exception => e
          # Rescue Exception (not just StandardError) on purpose: capture
          # everything so the parent always gets a diagnostic rather than a bare
          # non-zero exit.
          File.write(err, "#{e.class}: #{e.message}") rescue nil
          exit!(1)
        end
      end
    end

    private_class_method def self.wait_all!(jobs)
      failures = []
      jobs.each do |(pid, _part, err)|
        Process.waitpid(pid)
        next if $?.success?

        detail = (File.read(err) if File.exist?(err)) || "exit status #{$?.exitstatus.inspect}"
        failures << "worker #{pid}: #{detail}"
      end
      return if failures.empty?

      raise WorkerError, "parallel serialization failed (#{failures.size} worker(s)): #{failures.join('; ')}"
    end

    # Stream each part into `io` in order, inserting one `separator` between
    # consecutive parts so the result equals the serial join across slice
    # boundaries. Every part corresponds to a non-empty slice (the launch loop
    # never creates a worker for an empty slice), so each part — even one whose
    # items serialized to zero bytes — takes its boundary separator; skipping
    # zero-byte parts would drop a separator and diverge from the serial join.
    private_class_method def self.concat_parts!(io, parts, separator)
      parts.each_with_index do |part, i|
        io.write(separator) unless i.zero?
        File.open(part, "r") { |f| IO.copy_stream(f, io) }
      end
    end

    class WorkerError < StandardError; end
  end
end
