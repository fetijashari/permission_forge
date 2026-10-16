# frozen_string_literal: true

module PermissionForge
  # Whether this process can use its database, asked where the answer may be
  # "no" without anything being wrong with the app: at boot (BootChecks) and
  # when auto-applied masking reads the Resource table (MaskedModels).
  #
  # A process may have no database to use: a Docker build precompiles assets
  # before any database exists, a fresh `rails new --skip-kamal` app comments
  # its production database paths out (the deploy supplies DATABASE_URL at
  # runtime), a worker starts while the database fails over. The same app
  # without the gem boots in each case, so nothing the gem does at boot may
  # abort it then.
  #
  # Connecting can fail in Rails' own code in more ways than
  # ActiveRecord::ActiveRecordError (CONNECT_ERRORS): the sqlite3 adapter
  # refuses a configuration without a database file with an ArgumentError,
  # and an adapter whose driver gem is not installed raises a LoadError.
  # Those two are rescued only around a call that runs Rails' connection
  # code alone (a ping, `table_exists?`), never around the gem's own code: an
  # ArgumentError there is a bug and still raises.
  #
  # @api private
  module DatabaseReach
    # What connecting to a database raises when this process cannot use it:
    # not reachable, not created, not configured, no adapter (Active Record's
    # errors); a configuration the adapter refuses (ArgumentError: sqlite3's
    # "No database file specified"); an adapter whose driver gem is missing
    # (LoadError).
    CONNECT_ERRORS = [ActiveRecord::ActiveRecordError, ArgumentError, LoadError].freeze

    # What a read raises when the database went away after it answered, or
    # the table is not there yet (not migrated): the errors a boot step or a
    # read of the Resource rows is skipped on.
    READ_ERRORS = [ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid].freeze

    class << self
      # Connects and pings. `connection_pool.with_connection` alone is not
      # enough: since Rails 7.2 it hands back a connection that has not
      # connected yet, so an unreachable database looked available.
      #
      # @param model [Class] an ActiveRecord model whose database is asked
      #   (the gem's tables by default)
      # @return [Exception, nil] what connecting raised (CONNECT_ERRORS), nil
      #   when the database answered
      def problem(model = PermissionForge::PermissionSet)
        model.connection_pool.with_connection(&:verify!)
        nil
      rescue *CONNECT_ERRORS => e
        e
      end

      # @param model [Class] an ActiveRecord model
      # @return [Boolean] whether the model's table is there; false when its
      #   database cannot be used (CONNECT_ERRORS)
      def table_exists?(model)
        model.table_exists?
      rescue *CONNECT_ERRORS
        false
      end
    end
  end
end
