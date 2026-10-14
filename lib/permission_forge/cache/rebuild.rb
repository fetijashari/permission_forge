# frozen_string_literal: true

module PermissionForge
  module Cache
    # Stores a freshly built permission hash — or managed-actions index
    # (ControllerActions::ManagedIndex) — unless it may have been built across
    # an invalidation, in which case it is not left in the shared cache.
    #
    # The race: a rebuild reads the permission rows, a commit invalidates the
    # user, and only then does the rebuild store what it read. Every
    # invalidation leaves a per-user stamp (Cache::Invalidation); a rebuild
    # reads the stamp before it builds and again after it stored. Only when
    # both reads return the same stamp is the entry kept:
    #
    #   - the stamp changed: the entry is removed at once (the repeat may take
    #     long, or raise) and the hash is built once more, ATTEMPTS times in all;
    #   - there is no stamp: the rebuild writes one first and reads it back. A
    #     missing stamp and a stamp that could not be read look the same, so a
    #     rebuild never concludes anything from two empty reads;
    #   - the store cannot keep a stamp (it is down, or it stores nothing): the
    #     hash is built once and not stored;
    #   - a store call raises (a store without a failsafe): taken as the
    #     answer an ActiveSupport store gives instead — nothing read, nothing
    #     written — so the request still gets the hash it built;
    #   - anything raises along the way: the entry is removed.
    #
    # The caller gets the hash it built in every case. Whether the shared cache
    # kept it is the second value.
    #
    # A hash that must not be shared at all — it was built inside a database
    # transaction that reads from a snapshot (OpenTransaction.withholding) —
    # is built without a single call to the store (#withhold).
    #
    # @api private
    class Rebuild
      # A rebuild that raced an invalidation is repeated once. Racing a second
      # one is rare (two commits within two rebuilds), and repeating without a
      # limit could keep a request busy for as long as records are being saved.
      ATTEMPTS = 2

      def self.call(...) = new(...).call

      # @param key [String] the cache key of the hash
      # @param stamp_key [String] where the user's invalidation stamp lives
      # @param user_id [Object, nil] for the failure report
      # @param build [#call] returns [hash, ttl]; reads the rows — past
      #   ActiveRecord's query cache, or a repeat reads what the first build read
      def initialize(key:, stamp_key:, user_id:, build:, cache: PermissionForge.cache)
        @key = key
        @stamp_key = stamp_key
        @user_id = user_id
        @build = build
        @cache = cache
      end

      # @yieldreturn [Boolean] when a block is given, called after the stamp
      #   was read and before the entry is written: false keeps the entry out
      #   of the store (a variant whose index entry was not written)
      # @return [Array(Hash, Boolean)] the hash as built, and whether the shared
      #   cache kept it
      def call(&before_write)
        @before_write = before_write
        hash = nil
        ATTEMPTS.times do
          hash, outcome = attempt(current_stamp)
          return [hash, true] if outcome == :kept
          break unless outcome == :overtaken
        end
        [hash, false]
      end

      # Builds and leaves the store alone: no read, no write, no removal. An
      # entry that is there stays there — it holds committed rows, and
      # whoever changes them invalidates it after the commit.
      #
      # @return [Hash] the hash as built
      def withhold
        @build.call.first
      end

      private

      # The stamp to check against: the one in the store, or a new one when
      # there is none — nil when the store does not give it back.
      def current_stamp
        stamp = answered { @cache.read_fresh(@stamp_key) }
        return stamp if stamp

        stamp = SecureRandom.hex(8)
        written = answered { @cache.write(@stamp_key, stamp, ttl: PermissionForge.configuration.cache_ttl) }
        stamp if written && answered { @cache.read_fresh(@stamp_key) } == stamp
      end

      # @return [Array(Hash, Symbol)] the hash and what became of it:
      #   :kept, :overtaken (an invalidation happened meanwhile — worth another
      #   attempt) or :not_stored (the store did not take it — repeating the
      #   build would change nothing)
      def attempt(stamp)
        hash, ttl = @build.call
        stored = stamp && ready_to_write? && answered { @cache.write(@key, hash, ttl: ttl) }
        outcome = stored ? verify(stamp) : :not_stored
        [hash, outcome]
      ensure
        # Without a stamp nothing was written. With one, a write was sent:
        # also one the store said it did not take may have been applied.
        discard if stamp && outcome != :kept
      end

      # What must happen before the entry is written, after the stamp was
      # read (the block given to #call): an invalidation from then on either
      # finds what it wrote or makes the verification fail.
      def ready_to_write?
        @before_write.nil? || answered { @before_write.call } ? true : false
      end

      # A stamp that cannot be read back is not verified, and not worth a
      # second build either.
      def verify(stamp)
        current = answered { @cache.read_fresh(@stamp_key) }
        return :not_stored if current.nil?

        current == stamp ? :kept : :overtaken
      end

      # The store's answer; nil when the call raised.
      def answered
        yield
      rescue StandardError
        nil
      end

      # An entry this rebuild wrote and could not verify must not stay. When
      # the store does not confirm its removal either, the removal is owed
      # like an invalidation that failed (Backlog), and somebody has to know —
      # once: while it is owed, the rebuilds that follow fail the same way.
      def discard
        removed = begin
          @cache.expunge(@key)
        rescue StandardError => e
          error = e
          false
        end
        return if removed || !Invalidation.owe(user_id: @user_id, stamp_key: @stamp_key, keys: [@key])

        Failure.report(operation: :discard, user_id: @user_id, keys: [@key], error: error)
      end
    end
  end
end
