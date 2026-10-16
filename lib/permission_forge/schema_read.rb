# frozen_string_literal: true

require 'concurrent/map'
require 'concurrent/atomic/atomic_fixnum'

module PermissionForge
  # The one place the gem reads a model's columns, and whether a table is
  # there. Rails keeps both in its schema cache, read once per process (or
  # loaded from a schema cache dump), so a column a migration added while
  # the process was up — a running development server, an old process in a
  # rolling deploy — is not in it: a rule naming it would be refused, Sync
  # fields would not offer it, its timestamps would not be read-only.
  #
  # So a read that answers "no" — the name is not a column of the table, the
  # table is not there — reads the schema again first: the table's column
  # names are asked of the database (one metadata query) and, only when they
  # differ from what the cache holds, the model's column information is reset
  # (reset_column_information) and the answer asked again. A process whose
  # schema did not change never resets a model on the request path (a reset
  # drops the model's generated attribute methods while other threads use
  # it); the question the builder asks for every `_id` field's `_uuid`
  # variant costs one query per model and name per process. A name is read
  # again at most once per process while the table's columns stay as they
  # were read: a name found missing by a re-read is
  # *confirmed* missing and costs nothing afterwards, until something else
  # reads the table again (a reload in development, a migration in the
  # process, another re-read). A column that is there costs nothing extra:
  # no query, no lock.
  #
  # A list of columns cannot tell what it is missing. The reads that build
  # rows or reports from one — the field generator, Sync fields, the
  # admin's model catalog, the GDPR audit, the rule builder's columns — pass
  # `verify: true`: the column names are asked of the database (one
  # metadata query, no reset) and the schema is read again when they differ.
  # That is also how a removed column leaves a process: until such a read, a
  # column the cache still lists is answered as there (asking the database
  # on every "yes" would cost a query on the request path); after it, every
  # reader agrees it is gone, without reading again.
  #
  # Columns are the table's, as the database has them (`columns(model)`,
  # `ignored_columns` included, as a rule's column is resolved) or the
  # model's (`column_names`, `ignored_columns` excluded), as each caller says.
  #
  # @example
  #   PermissionForge::SchemaRead.column?(Customer, 'region')   # read again once if the cache says no
  #   PermissionForge::SchemaRead.columns(Customer, verify: true).keys
  #   PermissionForge::SchemaRead.table?(Customer, 'suppliers')
  #
  # @api private
  module SchemaRead
    # What the last re-read of a table found: `names` confirmed missing in
    # the columns identified by `token` (the cached columns hash's
    # object_id), and the `columns` it read.
    Confirmed = Data.define(:token, :names, :columns)

    # Seconds a table found missing stays missing before table? asks the
    # database again.
    TABLE_RECHECK = 30

    @confirmed = Concurrent::Map.new
    @claims = Concurrent::Map.new
    @tables = Concurrent::Map.new
    @enum_labels = Concurrent::Map.new
    @enum_claims = Concurrent::Map.new
    @rereads = Concurrent::AtomicFixnum.new

    class << self
      # The table's columns by name (`ignored_columns` included).
      #
      # @param model [Class] an Active Record model with a table
      # @param verify [Boolean] compare with the database first (see the module comment)
      # @return [Hash{String => ActiveRecord::ConnectionAdapters::Column}]
      def columns(model, verify: false)
        verify!(model) if verify
        table_columns(model)
      end

      # The model's column names (`ignored_columns` excluded).
      #
      # @param model [Class]
      # @param verify [Boolean] compare with the database first
      # @return [Array<String>]
      def column_names(model, verify: false)
        verify!(model) if verify
        model.column_names
      end

      # The table's column of that name, read again once when there is none.
      # A block picks the column out of the table's columns instead of the
      # exact name (a lookup that ignores case where the database does).
      #
      # @param model [Class]
      # @param name [String, Symbol]
      # @yieldparam columns [Hash{String => ActiveRecord::ConnectionAdapters::Column}]
      # @yieldreturn [ActiveRecord::ConnectionAdapters::Column, nil]
      # @return [ActiveRecord::ConnectionAdapters::Column, nil]
      def column(model, name, &pick)
        name = name.to_s
        pick ||= ->(columns) { columns[name] }
        pick.call(table_columns(model)) || (pick.call(table_columns(model)) if reread_missing?(model, [name]))
      end

      # @param model [Class]
      # @param name [String, Symbol]
      # @param ignored [Boolean] whether a column the model ignores (`ignored_columns`) counts
      # @return [Boolean] whether the table has the column (read again once before "no")
      def column?(model, name, ignored: true)
        name = name.to_s
        has?(model, name) { ignored ? table_columns(model).key?(name) : model.column_names.include?(name) }
      end

      # The names among `names` that are columns of the model
      # (`ignored_columns` excluded), the table read again once when some are
      # not.
      #
      # @param model [Class]
      # @param names [Array<String>]
      # @return [Array<String>] in the order of `names`
      def columns_among(model, names)
        names = names.map(&:to_s)
        found = names & model.column_names
        return found if found.size == names.size || !reread_missing?(model, names - found)

        names & model.column_names
      end

      # The block's answer about `name`; when it is "no" and the table has no
      # such column, the table is read again once and the block asked again.
      # For a predicate that also counts what is not a column (an attribute,
      # an alias, a method, a virtual field).
      #
      # @param model [Class]
      # @param name [String, Symbol]
      # @yieldreturn [Boolean]
      # @return [Boolean]
      def has?(model, name)
        return true if yield

        reread_missing?(model, [name.to_s]) && yield ? true : false
      end

      # Whether the connection has a data source (a table or a view) named
      # `table`; a "no" is asked of the database again, at most once every
      # TABLE_RECHECK seconds per model and name (a table a migration
      # creates later is found within that interval, and a name that stays
      # missing — a rule qualified with an alias — costs one query per
      # interval, never one per call).
      #
      # @param model [Class] a model on the connection
      # @param table [String] the name as written
      # @return [Boolean]
      def table?(model, table)
        table = table.to_s
        cache = schema_cache(model)
        return true if cache.data_source_exists?(table)
        return false unless table_recheck_due?([slot(model), table])

        cache.clear_data_source_cache!(table)
        @rereads.increment
        cache.data_source_exists?(table)
      end

      # Whether `label` is one of the labels of the native enum type `type`
      # (PostgreSQL: `CREATE TYPE ... AS ENUM`), as the database has them.
      # The labels are read once per process and type (one catalog query);
      # a label they lack is asked of the database again once, while the
      # labels stay as they were read: one a migration added while the
      # process runs (`ALTER TYPE ... ADD VALUE`). A type the database does
      # not know has no labels.
      #
      # @param model [Class] a model on the connection whose table has the column
      # @param type [String] the column's SQL type: the enum type's name
      # @param label [String]
      # @return [Boolean]
      def enum_label?(model, type, label)
        key = [model.connection_db_config.name, type.to_s]
        labels = @enum_labels.compute_if_absent(key) { enum_labels_of(model, type) }
        return true if labels.include?(label)
        return false unless @enum_claims.put_if_absent([key, labels.object_id, label], true).nil?

        @rereads.increment
        (@enum_labels[key] = enum_labels_of(model, type)).include?(label)
      end

      # @return [Integer] how many times this process read a table's schema again
      def rereads
        @rereads.value
      end

      # Forgets what was confirmed missing (tests).
      #
      # @return [void]
      def reset!
        [@confirmed, @claims, @tables, @enum_labels, @enum_claims].each(&:clear)
      end

      private

      # The type's labels in their order; none for a type the database does
      # not know (to_regtype answers NULL where a cast would raise and fail
      # the statement, and with it the caller's transaction).
      def enum_labels_of(model, type)
        model.connection_pool.with_connection do |connection|
          connection.select_values(<<~SQL.squish, 'SCHEMA').freeze
            SELECT enumlabel::text FROM pg_catalog.pg_enum
            WHERE enumtypid = to_regtype(#{connection.quote(type.to_s)}) ORDER BY enumsortorder
          SQL
        end
      end

      # Claims the re-read of a missing table when none ran in the last
      # TABLE_RECHECK seconds (one thread wins; the others answer "no").
      def table_recheck_due?(key)
        now = Time.now.to_f
        last = @tables[key]
        return @tables.put_if_absent(key, now).nil? if last.nil?
        return false if now - last < TABLE_RECHECK

        @tables.replace_pair(key, last, now)
      end

      def table_columns(model)
        schema_cache(model).columns_hash(model.table_name)
      end

      # The pool's schema cache, never `model.connection`'s: that reader
      # leases a connection to the thread for good and, from Rails 7.2,
      # raises under ActiveRecord.permanent_connection_checkout =
      # :disallowed. The pool's cache takes a connection only for the read
      # it makes, and is the one the connection's own cache is. Rails 7.1
      # has no pool cache (nor :disallowed): the connection's.
      def schema_cache(model)
        pool = model.connection_pool
        pool.respond_to?(:schema_cache) ? pool.schema_cache : model.connection.schema_cache
      end

      # Reads the table again when one of `names` is no column of it and was
      # not confirmed missing by the read the cache holds. true when it did.
      # Two threads asking at once: one reads, the other answers from what
      # the cache holds (no lock is held while Rails resets the model).
      def reread_missing?(model, names)
        columns = table_columns(model)
        missing = names - columns.keys
        return false if missing.empty? || confirmed?(model, columns, missing)

        claim = [slot(model), columns.object_id, missing.sort]
        return false unless @claims.put_if_absent(claim, true).nil?

        begin
          reread!(model, missing)
        ensure
          @claims.delete(claim)
        end
        true
      end

      def confirmed?(model, columns, missing)
        entry = @confirmed[slot(model)]
        !entry.nil? && entry.token == columns.object_id && (missing - entry.names).empty?
      end

      # Confirmed missing after the read: the names asked for now, the ones
      # confirmed before, and every column an earlier read had (the cache
      # being dropped, the last re-read) — a removed column among them — that
      # the new read lacks.
      def reread!(model, missing, live: live_names(model))
        known = missing | known_names(model)
        @rereads.increment
        model.reset_column_information unless current?(model, live)
        fresh = table_columns(model)
        @confirmed[slot(model)] = Confirmed.new(token: fresh.object_id, names: (known - fresh.keys).freeze, columns: fresh.keys.freeze)
      end

      # The columns the cache and the model hold and, from the last re-read,
      # the columns it read and the names it confirmed missing.
      def known_names(model)
        before = @confirmed[slot(model)]
        table_columns(model).keys | model.columns_hash.keys | (before ? before.names + before.columns : [])
      end

      # What the memo is keyed by: the class's object_id, so that a class
      # reloaded in development (another class) is read again, and the memo
      # does not keep the old one alive.
      def slot(model) = model.object_id

      def verify!(model)
        live = live_names(model)
        reread!(model, [], live: live) unless current?(model, live)
      end

      # Whether both reads Rails keeps — the schema cache's columns and the
      # model's own (`columns_hash`, which DDL run in the process does not
      # clear) — are the database's `live` names.
      def current?(model, live)
        live.sort == table_columns(model).keys.sort &&
          model.columns_hash.keys.sort == (live - model.ignored_columns.map(&:to_s)).sort
      end

      # The table's column names as the database has them now (a metadata
      # query).
      def live_names(model)
        model.connection_pool.with_connection { |connection| connection.columns(model.table_name).map(&:name) }
      end
    end
  end
end
