# frozen_string_literal: true

# Every test leaves the database as it found it. The fixture transaction
# rolls a test's rows back, but not where something committed them: a test
# that turns transactional tests off and cleans up only part of what it
# made, or DDL on MySQL — CREATE / ALTER / DROP TABLE commit the open
# transaction there (PostgreSQL and SQLite roll DDL back), so every row the
# test made before its DDL survives. The next tests then see them ("Name is
# already used by another Permission Set", a Home card too many).
#
# Before the first test each table's state is taken: its signature (the row
# count and, for a one-column primary key, its lowest and highest value —
# a test that deletes one row and adds another changes the highest) and,
# for a table of at most SNAPSHOT_LIMIT rows, the key of every row (the
# primary key, or every column for a table without one). After each test
# (after the fixture rollback) one query reads every signature again. A
# table whose signature differs is put back: the rows that were not there
# are removed (by key; above the highest id for a larger table), and a
# table that still differs — a row the test deleted, which cannot be made
# again — is reported and taken as it is now, so only the test that left
# the change fails, never the ones after it:
# - on MySQL, after a test that ran DDL: that is the database's behaviour,
#   nothing more is said;
# - otherwise the test fails, naming the tables, and the rows it deleted.
module CommittedRows
  INTERNAL = %w[schema_migrations ar_internal_metadata].freeze
  DDL = /\A\s*(?:CREATE|ALTER|DROP|RENAME|TRUNCATE)\b/i
  # Tables up to this many rows keep the key of every row.
  SNAPSHOT_LIMIT = 500

  # `key`: the columns that tell a row apart; `pk`: the one-column integer
  # or string primary key (nil otherwise: MIN / MAX would not work on every
  # type, a uuid on PostgreSQL); `integer`: it is an integer;
  # `signature`: [count, min pk, max pk]; `rows`: the Set of key tuples, nil
  # above SNAPSHOT_LIMIT.
  Table = Struct.new(:name, :key, :pk, :integer, :signature, :rows, keyword_init: true)

  class << self
    # { table => Table }, taken once per process before its first test (in a
    # forked worker: from the copy of the parent's database it starts from).
    def baseline
      @baseline ||= capture(connection.tables - INTERNAL)
    end

    # Replaces the baseline (tests of this guard put theirs back).
    attr_writer :baseline

    # The tables whose signature differs from the baseline:
    # { table => [then, now] } (each [count, min pk, max pk]).
    def changed
      present = connection.tables
      tables = baseline.values.select { |table| present.include?(table.name) }
      signatures(tables).filter_map do |table, now|
        [table.name, [table.signature, now]] unless now == table.signature
      end.to_h
    end

    # Puts the changed tables back where it can; what it cannot is taken as
    # the new baseline. Nil when nothing changed, else the report.
    #
    # @return [String, nil]
    def check!
      changed = self.changed
      return if changed.empty?

      deleted = remove!(changed.keys)
      message = "left committed rows (table => [before, after]): #{changed.inspect}"
      deleted.empty? ? message : "#{message}; deleted rows the database had before (table => keys): #{deleted.inspect}"
    end

    # Removes the rows each table gained since the baseline, then takes a
    # table that still differs (rows it lost) as it is now.
    #
    # @return [Hash{String => Array}] the baseline rows each table lost
    def remove!(names)
      deleted = {}
      with_foreign_keys_off do
        names.each do |name|
          table = baseline.fetch(name)
          lost = restore(table)
          deleted[name] = lost if lost.any?
        end
      end
      rebaseline!(names & changed.keys)
      deleted
    end

    # Takes `names` as they are now.
    def rebaseline!(names)
      return if names.empty?

      @baseline = baseline.merge(capture(names))
    end

    def mysql? = connection.adapter_name.match?(/mysql|trilogy/i)

    # Watches for DDL until the returned subscriber is unsubscribed; the
    # block is told the first time.
    def watch_ddl(&on_ddl)
      ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| on_ddl.call if DDL.match?(payload[:sql].to_s) }
    end

    private

    def connection = ActiveRecord::Base.connection

    def capture(names)
      tables = names.map { |name| describe(name) }
      signatures(tables).to_h do |table, signature|
        table.signature = signature
        table.rows = keys_of(table) if signature.first <= SNAPSHOT_LIMIT
        [table.name, table]
      end
    end

    def describe(name)
      pk = connection.primary_key(name)
      columns = connection.columns(name)
      key = pk.nil? ? columns.map(&:name) : Array(pk).map(&:to_s)
      type = pk_type(pk, columns)
      Table.new(name: name, key: key, pk: type && pk, integer: type == :integer)
    end

    # The type of a one-column integer or string primary key, else nil.
    def pk_type(primary_key, columns)
      return unless primary_key.is_a?(String)

      type = columns.find { |column| column.name == primary_key }&.type
      type if %i[integer string text].include?(type)
    end

    # One query for every table: [[table, [count, min pk, max pk]]].
    def signatures(tables)
      return [] if tables.empty?

      selects = tables.flat_map { |table| signature_sql(table) }
      values = connection.select_rows("SELECT #{selects.join(', ')}").first
      tables.zip(values.each_slice(3).zip(tables).map { |triple, table| signature(table, *triple) })
    end

    def signature(table, count, min, max)
      table.integer ? [count.to_i, min&.to_i, max&.to_i] : [count.to_i, min, max]
    end

    def signature_sql(table)
      from = connection.quote_table_name(table.name)
      return ["(SELECT COUNT(*) FROM #{from})", 'NULL', 'NULL'] unless table.pk

      pk = connection.quote_column_name(table.pk)
      ["(SELECT COUNT(*) FROM #{from})", "(SELECT MIN(#{pk}) FROM #{from})", "(SELECT MAX(#{pk}) FROM #{from})"]
    end

    def keys_of(table)
      columns = table.key.map { |column| connection.quote_column_name(column) }.join(', ')
      connection.select_rows("SELECT #{columns} FROM #{connection.quote_table_name(table.name)}").to_set
    end

    # The rows the table did not have are removed; the baseline rows it no
    # longer has are answered.
    def restore(table)
      return remove_above_max(table) unless table.rows

      now = keys_of(table)
      (now - table.rows).each { |row| delete_row(table, row) }
      (table.rows - now).to_a
    end

    def remove_above_max(table)
      max = table.signature.last
      return [] unless table.pk && max.is_a?(Integer)

      connection.execute("DELETE FROM #{connection.quote_table_name(table.name)} " \
                         "WHERE #{connection.quote_column_name(table.pk)} > #{Integer(max)}")
      []
    end

    def delete_row(table, row)
      conditions = table.key.zip(row).map do |column, value|
        quoted = connection.quote_column_name(column)
        value.nil? ? "#{quoted} IS NULL" : "#{quoted} = #{connection.quote(value)}"
      end
      connection.execute("DELETE FROM #{connection.quote_table_name(table.name)} WHERE #{conditions.join(' AND ')}")
    end

    def with_foreign_keys_off(&)
      return connection.disable_referential_integrity(&) if connection.respond_to?(:disable_referential_integrity)

      yield
    end
  end

  # Prepended to ActiveSupport::TestCase: the check runs after the fixture
  # rollback (ActiveRecord::TestFixtures#after_teardown), and a failure
  # raised here fails the test that left the rows.
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
      report = CommittedRows.check!
      return if report.nil? || (@pf_ddl_ran && CommittedRows.mysql?)

      flunk report
    end
  end
end
