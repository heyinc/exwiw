# frozen_string_literal: true

# Feasibility probe: can fork-based (copy-on-write) parallelism break the
# `as_extended_json` CPU wall on the MongoDB dump?
#
# Prior iterations established (see notes / mongodb-dump-perf memory) that for
# embed-heavy documents the dominant per-doc cost is `as_extended_json(mode:
# :relaxed)` (~82%) followed by `JSON.generate` (~12%) — both pure Ruby, so
# they hold the GVL and CANNOT be sped up by threads. Masking is already
# precompiled. The only untried lever for this pure-Ruby CPU cost (short of a
# native extension) is true multi-core parallelism, which on MRI means
# processes, not threads.
#
# This probe needs NO database: the Mongo driver hands documents back as plain
# Ruby Hashes containing BSON::ObjectId / Time / nested arrays, so we synthesize
# the exact same shape in memory and measure the serialization step in
# isolation. It compares:
#
#   - serial            : the production loop (JSON.generate(doc.as_extended_json))
#   - fork x W          : read the batch into an array, fork W workers that
#                         COW-inherit the array, each serializes its contiguous
#                         slice to a part file; the parent concatenates the parts
#                         in slice order into the final file.
#
# Both produce a single final JSONL file; the probe asserts they are
# byte-identical, then reports wall time and speedup per worker count. Fork
# overhead (page-table copy, part-file IO, concat) is INCLUDED in the parallel
# timing so the speedup is honest about what production would actually pay.
#
# Usage:
#   bundle exec ruby script/bench_mongodb_parallel_probe.rb
#
# Tunables (env):
#   PROBE_DOCS            documents per measured batch          (default 8000)
#   PROBE_POSTS_PER_DOC   embedded posts per document           (default 30)
#   PROBE_WORKERS         comma-separated worker counts to try  (default 2,4,8)

require 'json'
require 'etc'
require 'tmpdir'
require 'fileutils'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'bson'
require 'exwiw/parallel_serializer'

DOCS          = Integer(ENV.fetch('PROBE_DOCS', 8_000))
POSTS_PER_DOC = Integer(ENV.fetch('PROBE_POSTS_PER_DOC', 30))
WORKER_COUNTS = ENV.fetch('PROBE_WORKERS', '2,4,8').split(',').map { |w| Integer(w.strip) }

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def realtime
  t0 = monotonic
  yield
  monotonic - t0
end

# Build documents matching script/bench_mongodb_dump.rb's seed shape exactly:
# a user with ObjectId _id/shop_id, Time stamps, and POSTS_PER_DOC embedded
# posts each carrying an ObjectId and a Time. This is precisely what the Mongo
# Ruby driver materializes per result document.
def build_docs(count, posts_per_doc)
  shop_id = BSON::ObjectId.new
  now = Time.now.utc
  count.times.map do |i|
    posts = posts_per_doc.times.map do |j|
      {
        '_id' => BSON::ObjectId.new,
        'title' => "Post title #{i}-#{j} with some representative body length text",
        'body' => 'lorem ipsum ' * 8,
        'likes' => j,
        'created_at' => now,
      }
    end
    {
      '_id' => BSON::ObjectId.new,
      'name' => "User #{i}",
      'email' => "user#{i}@example.com",
      'shop_id' => shop_id,
      'posts' => posts,
      'updated_at' => now,
      'created_at' => now,
    }
  end
end

def serialize_line(doc)
  JSON.generate(doc.as_extended_json(mode: :relaxed))
end

# Both the serial baseline and the parallel path now go through the real
# production component, Exwiw::ParallelSerializer — so this probe validates the
# shipping code, not a throwaway copy of it, and the byte-identical assertion
# compares like-for-like (the component joins lines with "\n", no trailing
# newline, on every worker count including 1).
def serial_to_file(docs, path)
  File.open(path, 'w') do |file|
    Exwiw::ParallelSerializer.write(file, docs, workers: 1) { |doc| serialize_line(doc) }
  end
end

def parallel_to_file(docs, workers, path)
  File.open(path, 'w') do |file|
    # min_batch: 1 forces the fork path so we measure it even on small batches.
    Exwiw::ParallelSerializer.write(file, docs, workers: workers, min_batch: 1) do |doc|
      serialize_line(doc)
    end
  end
end

# Serialize-only (no concat): fork W workers writing their slice to part files,
# wait, but skip the parent's merge — isolates the pure parallel-serialization
# gain from the concat (double-IO) tax the component pays in parallel_to_file.
def parallel_to_parts(docs, workers, tmpdir)
  slice = (docs.size / workers.to_f).ceil
  pids = []
  workers.times do |w|
    lo = w * slice
    break if lo >= docs.size

    hi = [lo + slice, docs.size].min
    part = File.join(tmpdir, "part_#{w}.jsonl")
    pid = fork do
      File.open(part, 'w') do |file|
        (lo...hi).each { |i| file.print(serialize_line(docs[i]), "\n") }
      end
      # Skip at_exit / GC finalization in the child — its only job is the file.
      exit!(0)
    end
    pids << pid
  end
  pids.each { |pid| Process.waitpid(pid) }
end

puts "Parallel-serialization feasibility probe"
puts "  cores (Etc.nprocessors): #{Etc.nprocessors}"
puts "  batch: #{DOCS} docs x #{POSTS_PER_DOC} embedded posts; workers tried: #{WORKER_COUNTS.inspect}"
puts

print "Building #{DOCS} synthetic docs ... "
docs = nil
build_wall = realtime { docs = build_docs(DOCS, POSTS_PER_DOC) }
printf("done in %.2fs\n\n", build_wall)

Dir.mktmpdir('exwiw_parallel_probe') do |tmpdir|
  serial_path = File.join(tmpdir, 'serial.jsonl')

  # Warm up + measure serial twice, keep the faster (machine load is noisy).
  serial_to_file(docs, serial_path)
  serial_wall = [realtime { serial_to_file(docs, serial_path) },
                 realtime { serial_to_file(docs, serial_path) }].min
  serial_bytes = File.size(serial_path)
  printf("%-18s  time=%7.3fs  (baseline)        output=%.1fMB\n",
         'serial', serial_wall, serial_bytes / 1024.0 / 1024.0)

  WORKER_COUNTS.each do |w|
    par_path = File.join(tmpdir, "parallel_#{w}.jsonl")
    # Full path (serialize in parallel + concat) — what production would pay.
    par_wall = [realtime { parallel_to_file(docs, w, par_path) },
                realtime { parallel_to_file(docs, w, par_path) }].min
    # Same, minus the concat, to isolate the double-IO merge tax.
    noconcat_wall = [realtime { parallel_to_parts(docs, w, tmpdir) },
                     realtime { parallel_to_parts(docs, w, tmpdir) }].min
    identical = FileUtils.identical?(serial_path, par_path)
    printf("%-18s  time=%7.3fs  speedup=%5.2fx  (serialize-only %5.2fx)  byte-identical=%s\n",
           "fork x #{w}", par_wall, serial_wall / par_wall,
           serial_wall / noconcat_wall, identical)
    warn "  !! output DIVERGED for fork x #{w}" unless identical
  end
end

puts
puts "Note: parallel timings INCLUDE fork + part-file IO + concat overhead, so"
puts "the speedup reflects what a production fork-pool write path would pay."
