# frozen_string_literal: true

require 'securerandom'

module PermissionForge
  # Carries auto-applied masking (MaskedModels) to every process. The
  # concern is mixed into a model class in the process that loads it: at
  # boot, and in the process that commits the first Resource row for a new
  # model. Every other process would serve that model unmasked until it
  # restarts — unless it hears of it (docs/masked-attributes.md).
  #
  # When a setting takes its models from the Resource rows
  # (MaskedModels.row_driven?):
  #   - Writer: the process that commits a row naming a model for the first
  #     time (no other row in any tenant has the name, or this process had
  #     not masked it: two rows committed together) applies the concern and
  #     writes a new random token under KEY in the shared store, no expiry.
  #   - Reader: each executor run (request or job) reads KEY once (check!);
  #     a token it has not synced with makes it apply to every named model.
  #   - A process that reads no token (evicted, flushed) writes one and
  #     syncs; every other process then syncs once too. Losing the token
  #     costs one `pluck` per process, never a model left unmasked.
  #   - A store that does not answer is left alone for RETRY_PAUSE seconds,
  #     then one request or job per process probes it; logged once per
  #     outage. An announcement the store did not take is owed and written
  #     once it answers.
  # When every setting that is on is a list, the models are fixed by the
  # configuration: no token is read or written, and a process that has
  # synced does nothing per request. When both are off, check! returns
  # before reading anything (the hook stays: a setting may be switched on
  # after the boot step).
  #
  # Either way a process that has not synced (its boot could not reach the
  # database, a model could not be masked) applies at its next executor
  # run, and a development code reload applies again (`to_prepare`).
  #
  # The token needs a shared store. One that keeps nothing (:null, a
  # :null_store) is never asked for it: the token would read as lost on
  # every check. One that lives in each process (:memory, a :memory_store)
  # reaches no other process. In development, where Rails' default store is
  # one of these, each executor run re-reads the Resource names from the
  # database instead, at most every DATABASE_RECHECK seconds (database
  # recheck): a model named from a console, `bin/rails runner` or a rake task
  # is masked in the server at its next request. Other environments get no
  # such query (CacheWarnings warns at boot): a process then masks a model
  # first named in another one only after a restart.
  #
  # @api private
  module MaskingSync
    KEY = 'masked_models_version'

    # The token of a process that has not synced yet (no token can equal it).
    UNSYNCED = Object.new.freeze

    # Seconds the store is left alone after it did not answer.
    RETRY_PAUSE = 30

    # Development with a store that cannot carry the token: seconds between
    # two reads of the Resource names (one query each).
    DATABASE_RECHECK = 2

    # The cause named by the token warning when the store raised nothing: a
    # read of the token, and a read right after writing one, came back empty.
    SILENT_STORE = ' (it did not answer, or a read right after a write came back empty: the store is down, full, ' \
                   'or evicts the key at once)'

    # check!'s warning when a sync raised: a SECURITY one, the process fails open until the next sync.
    SYNC_FAILED = 'Auto-applied masking could not be synced: a model named in another process may stay unmasked here until the next sync'
    # The boot step's warning when a model could not be masked (boot!).
    INCOMPLETE_AT_BOOT = 'Auto-applied masking is not complete at boot (see the warnings above, or the Resource ' \
                         'table cannot be read): it is tried again at each request or job.'

    # One sync (or apply) at a time; one probe of a failing store at a time.
    SYNC_LOCK = Mutex.new
    PROBE_LOCK = Mutex.new

    # The token this process synced with (UNSYNCED, or nil for "synced
    # without one"), whether it owes the store an announcement, and until
    # when (monotonic seconds) which store is left alone. A failure while
    # @failing_until is set belongs to the outage already logged.
    @token = UNSYNCED
    @announcement_owed = false
    @failing_until = nil
    @failing_store = nil
    @recheck_after = nil

    class << self
      # Executor `to_run`. Row-driven: one store read; applies when another
      # process named a model since this one last synced. The store is not
      # read while it is failing (RETRY_PAUSE), nor at all for lists or a
      # store that keeps nothing: the token is then unknown (nil), and only
      # a process that has not synced applies (from the database). In
      # development with a store that cannot carry the token, the Resource
      # names instead (database_recheck?). Never raises.
      def check!
        return unless MaskedModels.enabled?
        return recheck_database if database_recheck?

        token = token_in_store? ? answered_token : nil
        sync(token) if changed?(token)
      rescue StandardError => e
        Warnings.emit(:masking_sync_failed, "#{SYNC_FAILED} (#{e.class}: #{e.message}).", severity: :security)
      end

      # After a Resource row naming `name` has been created or renamed and
      # committed: tells the other processes (a new token) when the name is
      # new to them — no other row has it — or when this process had not
      # masked the model before: rows committed together each see the
      # others, and the first to get here announces. Otherwise, and when
      # the settings are lists, applies the concern here only.
      #
      # @param name [String] the model the row names
      # @yieldreturn [Boolean] whether another Resource row has the name
      #   (asked only when it decides something)
      def named!(name)
        return unless MaskedModels.enabled?
        return apply!(name) unless token_in_store?

        masked_here?(name) && yield ? apply!(name) : announce!(name)
      end

      # The boot step: applies to every selected model and syncs with the
      # current token (read first, so a name committed meanwhile is seen
      # again by the next check). When a model could not be masked (or the
      # rows could not be read) the process stays unsynced and the next
      # request or job tries again.
      #
      # @return [Boolean] whether every selected model is masked
      def boot!
        done = sync(token_in_store? ? current_token : nil, always: true)
        Warnings.emit(:masking_sync_incomplete_at_boot, INCOMPLETE_AT_BOOT, severity: :security) unless done
        done
      end

      # `to_prepare`: after a code reload in development the model classes
      # are new and unmasked. At boot it runs before the boot step: nothing
      # to re-apply yet.
      def reloaded!
        return unless Rails.application&.initialized?

        reset!
        check!
      end

      # Forgets the token (the next check applies whatever the token says)
      # and that the store failed. Also what a boot that could not reach the
      # database leaves (BootChecks).
      def reset!
        SYNC_LOCK.synchronize { @token = UNSYNCED }
        @announcement_owed = false
        @failing_until = nil
        @recheck_after = nil
        MaskedModels.reset_warnings!
      end

      # @return [Boolean] whether this process has synced once
      def synced?
        !@token.equal?(UNSYNCED)
      end

      # @return [Boolean] whether the store recently did not answer (the
      #   store in use: one that replaced it has not failed yet)
      def store_failing?
        until_time = @failing_until
        !until_time.nil? && now < until_time && PermissionForge.cache.equal?(@failing_store)
      end

      # Whether this process learns of a model named in another one from the
      # Resource rows (development, a row-driven setting, a store that cannot
      # carry the token: it keeps nothing or lives in each process). Asks
      # nothing outside development.
      #
      # @return [Boolean]
      def database_recheck?
        return false unless Rails.env.development? && MaskedModels.row_driven?

        cache = PermissionForge.cache
        cache.process_local? || !cache.keeps_entries?
      end

      private

      # Whether the token is read and written: a row-driven setting and a
      # store that keeps entries, outside a database recheck.
      #
      # @return [Boolean]
      def token_in_store?
        MaskedModels.row_driven? && PermissionForge.cache.keeps_entries? && !database_recheck?
      end

      # The database recheck: every model the Resource rows name, at most
      # every DATABASE_RECHECK seconds — and at each run until it succeeded
      # once (a process that has not synced).
      def recheck_database
        return if synced? && @recheck_after && now < @recheck_after

        @recheck_after = now + DATABASE_RECHECK
        sync(nil, always: true)
      end

      # Applies the concern to one model in this process.
      def apply!(name)
        SYNC_LOCK.synchronize { MaskedModels.apply(only: name) }
      end

      # Applies the concern here, then tells the other processes. The token
      # it writes is not taken as this process's own: another process may
      # have written one since this one last checked, so the next check
      # syncs once more.
      #
      # A token the store does not take (it is down, or raises) is owed:
      # this process writes a new one at its first request or job after the
      # store answers again (after RETRY_PAUSE). Never raises for the store.
      def announce!(name)
        apply!(name)
        return if publish_token

        Warnings.emit("masking_sync.token_not_taken.#{name}",
                      "The cache store did not take the masking token: other processes mask #{name} once the " \
                      'store answers again and this process has written it.', severity: :security)
      end

      # The token to check against — nil while the store is failing. A
      # token this process owes the store (an announcement it did not take)
      # is written first, once the store answers.
      #
      # @return [String, nil]
      def answered_token
        return if store_failing?
        return owed_or_current_token unless @failing_until

        probe_store
      end

      # The pause after a failure is over: one thread asks the store again;
      # the others keep the pause (nil) instead of each waiting for a store
      # that may still be gone.
      def probe_store
        return unless PROBE_LOCK.try_lock

        begin
          owed_or_current_token
        ensure
          PROBE_LOCK.unlock
        end
      end

      def owed_or_current_token
        token = current_token
        token && @announcement_owed ? (publish_token || token) : token
      end

      # Writes a new token (no expiry). Remembers it as owed when the store
      # does not take it, and starts the back-off.
      #
      # @return [String, nil] the token written
      def publish_token
        token = SecureRandom.uuid
        written = PermissionForge.cache.write_permanent(KEY, token)
        store_failed! unless written
        @announcement_owed = !written
        token if written
      rescue StandardError => e
        @announcement_owed = true
        store_failed!(e)
        nil
      end

      # The token in the store — or, when there is none, a new one written
      # (with no expiry) and read back: whatever token is there then, also
      # one another process wrote meanwhile. nil when the store did not
      # answer: it is left alone for RETRY_PAUSE. A read that raised is not
      # followed by a write.
      #
      # @return [String, nil]
      def current_token
        cache = PermissionForge.cache
        token = cache.read_fresh(KEY) || (cache.read_fresh(KEY) if cache.write_permanent(KEY, SecureRandom.uuid))
        token ? store_answered! : store_failed!
        token
      rescue StandardError => e
        store_failed!(e)
        nil
      end

      def store_answered!
        @failing_until = nil
      end

      # Warned once per outage: the first failure after the store answered.
      # The warning names the cause (the error, or what a silent store did)
      # and the remedy.
      def store_failed!(error = nil)
        first = @failing_until.nil?
        @failing_until = now + RETRY_PAUSE
        @failing_store = PermissionForge.cache
        return unless first

        Warnings.emit(:masking_sync_store_failed,
                      'The cache store did not give or keep the masking token' \
                      "#{error ? " (#{error.class}: #{error.message})" : SILENT_STORE}: auto-applied " \
                      "masking is not synced with other processes for the next #{RETRY_PAUSE} seconds — a model " \
                      'a Resource row names in another process is masked here once the store answers. A store ' \
                      'that is up but loses the token at once cannot sync masking: use a shared store that keeps ' \
                      'entries, or include PermissionForge::Concerns::MaskedAttributes in the models ' \
                      '(docs/masked-attributes.md).', severity: :security)
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Whether `token` is one this process has not synced with. An unknown
      # one (nil: the store did not answer) only for a process that never
      # synced.
      def changed?(token)
        token.nil? ? !synced? : token != @token
      end

      # Whether this process has the concern on the model (false for a name
      # that resolves to no model here: not known to be masked).
      def masked_here?(name)
        MaskedModels.masked?(name)
      end

      def sync(token, always: false)
        SYNC_LOCK.synchronize do
          return true if !always && synced? && token == @token

          applied = MaskedModels.apply
          @token = token if applied
          applied
        end
      end
    end
  end
end
