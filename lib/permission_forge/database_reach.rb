# frozen_string_literal: true

module PermissionForge
  # Whether this process can use its database, asked where the answer may be
  # "no" without anything being wrong with the app: at boot (BootChecks),
  # when auto-applied masking reads the Resource table (MaskedModels,
  # MaskingSync), and wherever the audit table is looked for.
  #
  # A process may have no database to use: a Docker build precompiles assets
  # before any database exists, a fresh `rails new --skip-kamal` app comments
  # its production database paths out (the deploy supplies DATABASE_URL at
  # runtime), a worker starts while the database fails over. The same app
  # without the gem boots in each case, so nothing the gem does at boot may
  # abort it then.
  #
  # Connecting can fail in Rails' own code in more ways than
  # ActiveRecord::ActiveRecordError: the sqlite3 adapter refuses a
  # configuration without a database file with an ArgumentError. It is
  # rescued only around a call that runs Rails' connection code alone (a
  # ping, `table_exists?`), never around the gem's own code: an
  # ArgumentError there is a bug and still raises. (An adapter whose driver
  # gem is missing fails while Active Record loads, before any of this runs,
  # with or without the gem.)
  #
  # Every place that asks whether a table is there and may answer "no"
  # quietly asks table_exists? here; one whose "no" would fail open passes
  # the narrower UNAVAILABLE_ERRORS (Audit.table_available?: a check that
  # fails for another reason still raises out of Audit.record, and the
  # change it records rolls back, as before). Services::HostKeyGuard lets a
  # failed read propagate to its own rescue (READ_ERRORS), so that a pass
  # is never remembered from a check that could not look.
  #
  # @api private
  module DatabaseReach
    # The database cannot be used at all: not reachable (refused, timed out,
    # lost), not created, not configured (no adapter, an adapter that refuses
    # its configuration: sqlite3's "No database file specified").
    UNAVAILABLE_ERRORS = [ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError,
                          ActiveRecord::AdapterNotSpecified, ActiveRecord::AdapterNotFound, ArgumentError].freeze

    # What a ping or a table check that may answer "no" quietly rescues: the
    # above, and any other error Active Record raises for the query.
    CONNECT_ERRORS = [ActiveRecord::ActiveRecordError, ArgumentError].freeze

    # What a read raises when the database went away after it answered, or
    # the table is not there yet (not migrated): the errors a boot step or a
    # read of the Resource rows is skipped on.
    READ_ERRORS = [ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid].freeze

    class << self
      # Connects and pings. `connection_pool.with_connection` alone is not
      # enough: since Rails 7.2 it hands back a connection that has not
      # connected yet, so an unreachable database looked available.
      #
      # @param model [Class, nil] an ActiveRecord model whose database is
      #   asked; nil for the gem's tables (referenced inside the rescue: the
      #   first reference loads the model, and Active Record with it)
      # @return [Exception, nil] what connecting raised (CONNECT_ERRORS), nil
      #   when the database answered
      def problem(model = nil)
        (model || PermissionForge::PermissionSet).connection_pool.with_connection(&:verify!)
        nil
      rescue *CONNECT_ERRORS => e
        e
      end

      # @param model [Class] an ActiveRecord model
      # @param errors [Array<Class>] what counts as "cannot be asked"
      #   (CONNECT_ERRORS, or the narrower UNAVAILABLE_ERRORS)
      # @yieldparam error [Exception] what the check raised, when it did
      # @return [Boolean] whether the model's table is there; false when the
      #   check raised one of `errors`
      def table_exists?(model, errors: CONNECT_ERRORS)
        model.table_exists?
      rescue *errors => e
        yield e if block_given?
        false
      end
    end
  end
end
