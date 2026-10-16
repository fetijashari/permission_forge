# frozen_string_literal: true

# Every test leaves the database as it found it. The fixture transaction
# rolls a test's rows back, but not where something committed them: a test
# that turns transactional tests off and cleans up only part of what it
# made, or DDL on MySQL — CREATE / ALTER / DROP TABLE commit the open
# transaction there (PostgreSQL and SQLite roll DDL back), so every row the
# test made before its DDL survives. The next tests then see them ("Name is
# already used by another Permission Set", a Home card too many).
#
# After each test (after the fixture rollback) the row count of every table
# is compared with the counts taken before the first test. A difference is
# removed (rows above the id the table had then), so the next test starts
# clean, and:
# - on MySQL, after a test that ran DDL: that is the database's behaviour,
#   nothing more is said;
# - otherwise the test fails, naming the tables it left rows in.
module CommittedRows
  INTERNAL = %w[schema_migrations ar_internal_metadata].freeze
  DDL = /\A\s*(?:CREATE|ALTER|DROP|RENAME|TRUNCATE)\b/i

  Baseline = Struct.new(:counts, :max_ids)

  class << self
    # Taken once per process, before its first test (in a forked worker:
    # from the copy of the parent's database it starts from).
    def baseline
      @baseline ||= begin
        tables = connection.tables - INTERNAL
        Baseline.new(counts(tables), tables.to_h { |table| [table, max_id(table)] })
      end
    end

    # The tables whose row count differs from the baseline: { table => [then, now] }.
    def changed
      tables = baseline.counts.keys & connection.tables
      counts(tables).filter_map { |table, now| [table, [baseline.counts[table], now]] unless now == baseline.counts[table] }.to_h
    end

    # Removes the rows each changed table gained since the baseline.
    def remove!(tables)
      with_foreign_keys_off do
        tables.each do |table|
          next unless (floor = baseline.max_ids[table])

          connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id > #{Integer(floor)}")
        end
      end
    end

    def mysql? = connection.adapter_name.match?(/mysql|trilogy/i)

    # Watches for DDL until the returned subscriber is unsubscribed; the
    # block is told the first time.
    def watch_ddl(&on_ddl)
      ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| on_ddl.call if DDL.match?(payload[:sql].to_s) }
    end

    private

    def connection = ActiveRecord::Base.connection

    def counts(tables)
      return {} if tables.empty?

      selects = tables.map { |table| "(SELECT COUNT(*) FROM #{connection.quote_table_name(table)})" }
      tables.zip(connection.select_rows("SELECT #{selects.join(', ')}").first.map(&:to_i)).to_h
    end

    # The table's highest id; nil for a table without an integer id.
    def max_id(table)
      return unless connection.columns(table).any? { |column| column.name == 'id' && column.type == :integer }

      connection.select_value("SELECT MAX(id) FROM #{connection.quote_table_name(table)}").to_i
    end

    def with_foreign_keys_off(&)
      return connection.disable_referential_integrity(&) if connection.respond_to?(:disable_referential_integrity)

      yield
    end
  end

  # Prepended to ActiveSupport::TestCase: the count is taken after the
  # fixture rollback (ActiveRecord::TestFixtures#after_teardown), and a
  # failure raised here fails the test that left the rows.
  module Check
    def before_setup
      CommittedRows.baseline
      @pf_ddl_ran = false
      @pf_ddl_watch = CommittedRows.watch_ddl { @pf_ddl_ran = true }
      super
    end

    def after_teardown
      super
    ensure
      ActiveSupport::Notifications.unsubscribe(@pf_ddl_watch) if @pf_ddl_watch
      check_committed_rows
    end

    private

    def check_committed_rows
      changed = CommittedRows.changed
      return if changed.empty?

      CommittedRows.remove!(changed.keys)
      return if @pf_ddl_ran && CommittedRows.mysql?

      flunk "left committed rows (table => [before, after]): #{changed.inspect}"
    end
  end
end
