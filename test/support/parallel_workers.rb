# frozen_string_literal: true

require 'etc'
require 'fileutils'
require 'tmpdir'

# The SQLite suite runs in forked worker processes (Rails' `parallelize`).
#
# The database is in memory, and sqlite3 closes a connection a child inherits,
# so a worker cannot use the parent's. Rails' own answer (a database file per
# worker, built from the schema) would miss the tables the test files create
# when they load and the rows test_helper writes. Instead the parent copies
# its whole in-memory database to a file just before forking, and every
# worker copies that file into a new in-memory database of its own
# (SQLite's online backup), so each worker starts where a serial run starts.
#
# PostgreSQL and MySQL runs stay serial: their workers would share one
# database. PARALLEL_WORKERS=1 runs the SQLite suite in one process (Rails
# reads PARALLEL_WORKERS); otherwise DEFAULT workers.
module ParallelWorkers
  DEFAULT = [Etc.nprocessors, 8].min

  # Held by a test that uses a resource every worker shares (the local
  # Redis database the cache tests write to and flush).
  SHARED_RESOURCE_LOCK = File.join(Dir.tmpdir, 'permission_forge_test_shared_resource.lock')

  class << self
    def enabled?
      ENV['DB'].to_s.empty?
    end

    # Parent, before forking: the database as test_helper and the test files
    # left it, to a file; then no connection is left open to inherit.
    def save_database
      @parent = Process.pid
      @path = File.join(Dir.tmpdir, "permission_forge_test_#{@parent}.sqlite3")
      FileUtils.rm_f(@path)
      target = SQLite3::Database.new(@path)
      copy(from: ActiveRecord::Base.connection.raw_connection, to: target)
      target.close
      ActiveRecord::Base.connection_handler.clear_all_connections!
    end

    # Worker, after forking: a new in-memory database with the parent's
    # contents.
    def load_database
      ActiveRecord::Base.establish_connection
      source = SQLite3::Database.new(@path, readonly: true)
      copy(from: source, to: ActiveRecord::Base.connection.raw_connection)
      source.close
    end

    # Parent, when the run ends.
    def remove_database
      FileUtils.rm_f(@path) if @path && Process.pid == @parent
    end

    # Runs the block while no other worker (or other run on this machine)
    # holds the shared-resource lock.
    def exclusively
      File.open(SHARED_RESOURCE_LOCK, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    private

    def copy(from:, to:)
      backup = SQLite3::Backup.new(to, 'main', from, 'main')
      backup.step(-1)
      backup.finish
    end
  end

  # Included by a test class whose tests use a resource every worker
  # shares: each of its tests runs while it holds the lock.
  module SharedResource
    def run(...)
      ParallelWorkers.exclusively { super }
    end
  end
end
