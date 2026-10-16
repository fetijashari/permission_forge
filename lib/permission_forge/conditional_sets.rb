# frozen_string_literal: true

require 'digest/sha2'
require 'securerandom'

module PermissionForge
  # The permission sets with activation conditions (session flag, IP
  # allowlist, login hours) among those a user holds, and the variant of the
  # permission hash a request context selects among them.
  #
  # A condition is checked against the request that READS the hash, never
  # against the one that happened to build it (an MFA-verified session, an
  # office IP, a job without a context). So the shared cache keeps, per user:
  #
  #   - one base entry under permission_cache_key: the hash of the
  #     unconditional sets, in the public format, plus — only when the user
  #     holds conditional sets — this object under ENTRY_KEY (the conditions,
  #     and a token minted at that build);
  #   - one variant per combination of conditional sets that a context
  #     selects, in a slot of the base key: base key + KEY_INFIX + the
  #     bitmask of the selected sets among the user's conditional sets,
  #     sorted by id (#slot, 1..2^MAX_CACHED_SETS - 1). It holds the hash of
  #     the unconditional sets and those, in the public format, plus under
  #     VARIANT_KEY the fingerprint — a digest of the base's token and the
  #     selected ids — of the base entry and selection it was built for.
  #
  # A read serves a variant only when its fingerprint is the one the current
  # base entry names (.variant_hash): a variant is reachable only through
  # the base entry that minted its token. Anything else in the slot — the
  # variant of a base entry that is gone — is a miss, rebuilt and written
  # over. Every variant is stored through Cache::Rebuild under the user's
  # invalidation stamp, so one built across an invalidation is discarded
  # like a base.
  #
  # So an invalidation (PermissionCacheAccessor#invalidate_permissions,
  # Cache::UserKeys) removes the base entries only: the variants it leaves
  # can no longer be reached — every base build mints a new token — and go
  # with their TTL (clamped to config.conditional_set_cache_ttl like the
  # base's), or are written over. They still hold the profile, so where
  # personal data must go now — Services::DataSubjectErasure, the
  # enumerated cache:clear — Cache::VariantRemoval removes them: the slots
  # of a base key (.variant_keys: a fixed set, whatever the token). Erasure
  # removes every slot of each of the person's base keys without reading
  # anything; the clear, over every user, only those of a base key that has
  # an index entry (.index_key). The index entry says no more than that
  # variants may be stored under the base key (INDEX), so concurrent writers
  # write the same value; it is written after the variant's rebuild read
  # the user's stamp and before the variant is written (a variant whose
  # index entry could not be written is not stored), and outlives every
  # variant written after it (INDEX_TTL_MARGIN). A user who never had a
  # variant stored has none: the clear reads it and removes nothing.
  #
  # A user who holds more than MAX_CACHED_SETS conditional sets has the
  # variants built for the request that asks and kept on its instance only,
  # never stored or looked for — one build per request for such a user.
  #
  # Which conditional sets a context selects (#passing):
  #   - a context with an IP or session flags: those whose conditions pass
  #     (Services::PermissionSetConditionEvaluator), granting and muting alike;
  #   - no context at all — the resolver returned nothing (no resolver, as
  #     shipped): every conditional set, as before;
  #   - under config.conditional_sets_strict_mode, no request context — the
  #     resolver returned nothing, or neither an IP nor session flags (a job,
  #     the console; the time alone is not a request context): only the
  #     conditional MUTING sets, since a missing context must never grant and
  #     must never lift a lockdown either. With a request context, a muting
  #     set whose condition cannot be judged in it (an IP allowlist and no
  #     IP; a session flag and no :session_flags at all) applies too, for the
  #     same reason; granting sets are evaluated as they are. Without strict
  #     mode such a context is evaluated per set, as before: a job gets no
  #     MFA- or IP-gated grant, an IP-gated set fails without an IP, and the
  #     hours are checked.
  # The time the conditions are checked at is fixed once per selection
  # (.clocked), so the signature names the hour the evaluation saw.
  #
  # Everything here is plain data (Strings, Integers, Arrays, Data): it is
  # written to the store as a Hash (#dump) and kept on a user instance in
  # the memo (PermissionsMemo), which marshals with the user.
  #
  # @api private
  class ConditionalSets < Data.define(:sets, :token)
    # Where the base entry carries it.
    ENTRY_KEY = :conditional_sets
    # Where a stored variant carries the fingerprint of the base entry and
    # selection it was built for: taken off on every read, never part of
    # the hash.
    VARIANT_KEY = :variant_of
    # Between the base key and the slot in a variant's key.
    KEY_INFIX = '_c_'
    # After KEY_INFIX in the key of the index entry (a slot is a number).
    INDEX_NAME = 'index'
    # What the index entry holds: variants may be stored under the base key.
    INDEX = true
    # Seconds the index entry lives beyond config.cache_ttl, the longest a
    # variant written after it lives.
    INDEX_TTL_MARGIN = 60
    # The most conditional sets a user may hold for the variants to be cached:
    # erasure removes one slot per combination of them.
    MAX_CACHED_SETS = 6
    # Every slot a base key has.
    SLOTS = (1..((1 << MAX_CACHED_SETS) - 1))

    # One conditional set: what the evaluator reads of a PermissionSet.
    #
    # @api private
    Member = Data.define(:id, :muting, :requires_session_flag, :allowed_ips, :allowed_hours_start, :allowed_hours_end) do
      include PermissionForge::ActivationConditions

      def self.of(permission_set)
        new(id: permission_set.id, muting: permission_set.is_muting == true,
            requires_session_flag: permission_set.requires_session_flag, allowed_ips: permission_set.allowed_ips,
            allowed_hours_start: permission_set.allowed_hours_start, allowed_hours_end: permission_set.allowed_hours_end)
      end

      # A stored member — also one written by a version with fewer conditions.
      #
      # @raise [ArgumentError] for anything but a Hash
      def self.load(data)
        raise ArgumentError, "a conditional set is stored as a Hash, not #{data.class}" unless data.is_a?(Hash)

        new(**members.to_h { |name| [name, data[name]] })
      end

      def muting? = muting

      # Whether the set counts in `context`: its conditions pass — or it is
      # a muting set whose condition cannot be judged: one nobody can judge
      # (ActivationConditions#conditions_broken?: an IP entry that is not an
      # address, one hour of the two, the same hour twice) in every mode, or
      # one the context cannot answer (no IP for an IP allowlist, no flags
      # at all for a session flag) in strict mode. A lockdown that never
      # locked is the defect; a granting set never passes on such a condition.
      def applies?(context, strict)
        evaluator = Services::PermissionSetConditionEvaluator
        evaluator.call(permission_set: self, context: context) ||
          (muting && (conditions_broken? || (strict && evaluator.unjudgeable?(permission_set: self, context: context))))
      end
    end

    # The conditional sets a context selected: their ids, the fingerprint
    # of the base entry (token) and those ids, and whether the variant is
    # kept in the shared cache (MAX_CACHED_SETS).
    #
    # @api private
    Variant = Data.define(:ids, :fingerprint, :cached)

    # What a memo keeps about the hash it holds: the user's conditional sets,
    # the variant the hash was built for (nil: the base), and the signature
    # of the context that selected it.
    #
    # @api private
    Served = Data.define(:conditional, :variant, :signature) do
      # Whether `context` is, as far as the conditions go, the one that
      # selected the hash — cheaper than selecting again.
      def selected_by?(context)
        signature == ConditionalSets.signature(context)
      end

      # This selection, when `context` is the one that made it; a copy that
      # remembers `context`, when it selects the same variant (so the next
      # check is cheap again); nil when it selects another variant.
      #
      # @return [Served, nil]
      def reselect(context)
        return self if selected_by?(context)

        again = conditional.serve(context)
        again if again.variant == variant
      end

      # The store key of the hash: the base key, or the variant's slot
      # (one of ConditionalSets.variant_keys).
      def store_key(base_key)
        variant ? "#{base_key}#{KEY_INFIX}#{conditional.slot(variant.ids)}" : base_key
      end
    end

    class << self
      # @param permission_sets [Enumerable<PermissionSet>] the sets a user holds
      # @return [ConditionalSets, nil] nil when none is conditional
      def of(permission_sets)
        sets = permission_sets.select(&:conditional?).map { |set| Member.of(set) }
        new(sets: sets) if sets.any?
      end

      # @param data [Hash] what #dump wrote
      # @return [ConditionalSets]
      # @raise [ArgumentError] for data without a token — another version of
      #   the gem, or a foreign writer, left it: without the token every base
      #   would name the same variants
      def load(data)
        token = data[:token] if data.is_a?(Hash)
        raise ArgumentError, 'conditional sets are stored with a token' unless token.is_a?(String) && !token.empty?

        new(sets: Array(data[:sets]).map { |member| Member.load(member) }, token: token)
      end

      # Separates a stored base entry into the public hash and the conditional
      # sets it carries. An entry without them is returned as it is; one whose
      # conditional sets cannot be read is no entry at all.
      #
      # @return [Array(Hash, ConditionalSets|nil), nil]
      def split(entry)
        data = entry[ENTRY_KEY]
        return [entry, nil] unless data

        [entry.except(ENTRY_KEY), load(data)]
      rescue ArgumentError
        nil
      end

      # The sets a hash is built from: the unconditional ones, and those of
      # the variant when there is one.
      #
      # @param permission_sets [Enumerable<PermissionSet>]
      # @param variant [Variant, nil]
      # @return [Array<PermissionSet>]
      def build_sets(permission_sets, variant)
        return permission_sets.reject(&:conditional?) unless variant

        ids = variant.ids
        permission_sets.select { |set| set.unconditional? || ids.include?(set.id) }
      end

      # @return [String] the store key of the index entry of the base entry
      #   at `base_key` (#index)
      def index_key(base_key)
        "#{base_key}#{KEY_INFIX}#{INDEX_NAME}"
      end

      # Every key a variant of the base entry at `base_key` can be stored
      # under, whatever its token: one per slot (SLOTS).
      #
      # @param base_key [String]
      # @return [Array<String>]
      def variant_keys(base_key)
        SLOTS.map { |slot| "#{base_key}#{KEY_INFIX}#{slot}" }
      end

      # The entry a variant is stored as: the hash, and the fingerprint of
      # the base entry and selection it was built for (VARIANT_KEY).
      #
      # @param hash [Hash] in the public format
      # @param variant [Variant]
      # @return [Hash]
      def variant_entry(hash, variant)
        hash.merge(VARIANT_KEY => variant.fingerprint)
      end

      # The hash a stored variant holds — when it was built for `variant`:
      # this base entry (token) and this selection. nil for anything else in
      # the slot: the variant of a base entry that is gone, another
      # selection, an entry without a fingerprint.
      #
      # @param entry [Hash, nil] as read from the store
      # @param variant [Variant]
      # @return [Hash, nil] the hash in the public format
      def variant_hash(entry, variant)
        entry.except(VARIANT_KEY) if entry.is_a?(Hash) && entry[VARIANT_KEY] == variant.fingerprint
      end

      # The digest of a token and sorted ids that names a variant.
      #
      # @return [String]
      def fingerprint(token, ids)
        Digest::SHA256.hexdigest("#{token}:#{ids.join(',')}")[0, 32]
      end

      # Whether `context` says nothing a condition could be checked against:
      # the resolver returned nothing, or neither an IP nor session flags.
      # The time alone is not a request context.
      #
      # @param context [Hash, nil] what config.request_context_resolver returned
      # @return [Boolean]
      def no_context?(context)
        context.blank? || (context[:ip].blank? && Array(context[:session_flags]).empty?)
      end

      # The context with the time its conditions are checked at, fixed once:
      # the hour the evaluation sees is the hour the signature names. A
      # context that says nothing is left as it is (nothing is evaluated).
      #
      # @param context [Hash, #to_h, nil]
      # @return [Hash]
      def clocked(context)
        context = context.to_h unless context.is_a?(Hash)
        return context if context.blank? || context[:time]

        context.merge(time: Time.current)
      end

      # What of a context the conditions look at: the hour, not the second;
      # a copy of the flags (a resolver may hand out the array, or a flag, it
      # mutates); and for a context that selects without evaluating — none
      # at all, or none in strict mode — only that.
      #
      # @param context [Hash, nil] what config.request_context_resolver returned
      # @return [Array, Symbol]
      def signature(context)
        return :strict if strict? && no_context?(context)
        return :blank if context.blank?

        flags = context[:session_flags]
        [context[:ip], flags.nil? ? nil : Array(flags).map { |flag| -flag.to_s }, (context[:time] || Time.current).hour]
      end

      def strict?
        PermissionForge.configuration.conditional_sets_strict_mode == true
      end
    end

    # @param sets [Array<Member>]
    # @param token [String] minted for the base entry that carries this
    def initialize(sets:, token: SecureRandom.hex(8))
      super(sets: sets.freeze, token: token)
    end

    # @return [Hash] plain data for the store (see .load)
    def dump
      { token: token, sets: sets.map(&:to_h) }
    end

    # Whether the variants are kept in the shared cache (MAX_CACHED_SETS).
    #
    # @return [Boolean]
    def cacheable?
      sets.size <= MAX_CACHED_SETS
    end

    # @param context [Hash, nil] what config.request_context_resolver returned
    # @return [Served]
    def serve(context)
      context = self.class.clocked(context)
      Served.new(conditional: self, variant: variant(context), signature: self.class.signature(context))
    end

    # @return [Variant, nil] nil when the context selects no conditional set
    def variant(context)
      ids = passing(context).map(&:id).sort
      return if ids.empty?

      Variant.new(ids: ids, fingerprint: self.class.fingerprint(token, ids), cached: cacheable?)
    end

    # The slot of the variant of `ids`: the bitmask of those sets among the
    # user's conditional sets, sorted by id — 1..2^n - 1 for n sets, so
    # within SLOTS for a user whose variants are cached (#cacheable?).
    #
    # @param ids [Array<Integer>] some of the sets' ids (Variant#ids)
    # @return [Integer]
    def slot(ids)
      sorted = sets.map(&:id).sort
      ids.sum { |id| 1 << sorted.index(id) }
    end

    private

    def passing(context)
      klass = self.class
      strict = klass.strict?
      return sets.select(&:muting?) if strict && klass.no_context?(context)
      return sets if context.blank?

      sets.select { |member| member.applies?(context, strict) }
    end
  end
end
