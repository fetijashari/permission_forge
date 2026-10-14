# frozen_string_literal: true

require 'test_helper'
require_relative '../audit/runtime_support'

module PermissionForge
  module Concerns
    # A permission set with activation conditions (session flag, IP allowlist,
    # login hours) counts for the request context that is current when the
    # hash is READ — never for the one that happened to build it. The shared
    # cache keeps one base entry per user (the unconditional sets, carrying
    # the conditional ones and their conditions) and one variant per
    # combination of passing conditional sets (PermissionForge::ConditionalSets).
    #
    # Pre-release review: core-security #2 (probes C1–C3) and #8 (probe X1),
    # claims #6 and #7; the WS4 review's probes R1b, R2, R3, R4, R7, R14 and
    # R15 are the tests marked with their names.
    class ConditionalSetsPerContextTest < ActiveSupport::TestCase
      include PermissionForge::Audit::RuntimeSupport

      # The shape of a host's self-healing override of permissions_hash: an
      # empty hash is a miss, regenerate, read again.
      class SelfHealingUser < ::User
        def self.name = 'User'

        def permissions_hash
          cached = super
          return cached if cached.present? || @regenerating

          @regenerating = true
          begin
            regenerate_permissions
          ensure
            @regenerating = false
          end
          super
        end
      end

      class CountingMemoryStore < ActiveSupport::Cache::MemoryStore
        attr_accessor :reads, :writes

        def initialize(*)
          super
          @reads = 0
          @writes = []
        end

        def read(name, options = nil)
          @reads += 1
          super
        end

        def write(name, value, options = nil)
          @writes << [name, options && options[:expires_in]]
          super
        end
      end

      PUBLIC_KEYS = %i[profile preferences permissions].freeze

      setup do
        @store = CountingMemoryStore.new
        PermissionForge.configuration.cache_backend = @store
        PermissionForge.configuration.reset_cache_store!
        @user = create_user
        @context = {}
        @resolver_calls = 0
        test = self
        PermissionForge.configuration.request_context_resolver = lambda do
          test.instance_variable_set(:@resolver_calls, test.instance_variable_get(:@resolver_calls) + 1)
          test.instance_variable_get(:@context)
        end
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
        PermissionForge.configuration.request_context_resolver = -> { {} }
        PermissionForge.configuration.conditional_sets_strict_mode = false
        PermissionForge.configuration.snapshot_transactions = :auto
        PermissionForge.configuration.conditional_set_cache_ttl = 300
      end

      # --- the leak: probes C1–C3 -----------------------------------------------------

      test 'C1: an MFA-gated grant built in session A is not served to session B of the same user' do
        grant(requires_session_flag: 'mfa_verified')

        in_context(session_flags: ['mfa_verified']) { assert reader.can_delete?(:Customer) }
        in_context(session_flags: []) { assert_not reader.can_delete?(:Customer), 'session B got the MFA grant' }
        in_context(session_flags: ['mfa_verified']) { assert reader.can_delete?(:Customer) }
      end

      test 'C2: an IP-restricted grant built from the office is not served to a remote request' do
        grant(allowed_ips: '10.0.0.0/8')

        in_context(ip: '10.1.2.3') { assert reader.can_delete?(:Customer) }
        in_context(ip: '203.0.113.9') { assert_not reader.can_delete?(:Customer), 'the remote request got the office grant' }
      end

      test 'C3: a job without context (non-strict) does not leave the grant cached for a remote web request' do
        grant(allowed_ips: '10.0.0.0/8')

        in_context({}) { assert reader.can_delete?(:Customer), 'blank context, non-strict: the set counts' }
        in_context(ip: '203.0.113.9') { assert_not reader.can_delete?(:Customer), 'the web request got the job build' }
      end

      test 'login hours: the grant follows the hour of the request, not of the build' do
        grant(allowed_hours_start: 9, allowed_hours_end: 17)

        in_context(time: Time.current.change(hour: 12)) { assert reader.can_delete?(:Customer) }
        in_context(time: Time.current.change(hour: 20)) { assert_not reader.can_delete?(:Customer) }
      end

      test 'a conditional muting set mutes in the contexts whose conditions pass and only there' do
        unconditional_grant
        mute(requires_session_flag: 'lockdown')

        in_context(session_flags: ['lockdown']) { assert_not reader.can_delete?(:Customer) }
        in_context(session_flags: []) { assert reader.can_delete?(:Customer), 'the lockdown leaked into another session' }
        in_context(session_flags: ['lockdown']) { assert_not reader.can_delete?(:Customer) }
      end

      test 'two conditional sets: each combination of passing sets has its own hash' do
        grant(requires_session_flag: 'mfa_verified')
        office = create_permission_set(name: 'Office', allowed_ips: '10.0.0.0/8')
        create_permission_set_user(user: @user, permission_set: office)
        create_resource(permission_set: office, name: 'Customer', read_access: true, create_access: true)

        in_context(session_flags: ['mfa_verified'], ip: '10.0.0.1') { assert_equal [true, true], abilities(reader) }
        in_context(session_flags: ['mfa_verified'], ip: '203.0.113.9') { assert_equal [true, false], abilities(reader) }
        in_context(session_flags: [], ip: '10.0.0.1') { assert_equal [false, true], abilities(reader) }
        in_context(session_flags: [], ip: '203.0.113.9') { assert_equal [false, false], abilities(reader) }
        assert_equal 3, variant_keys.size, 'one variant per combination that passes a set'
      end

      # --- one instance across contexts: the memo -----------------------------------------

      test 'one instance follows the context: the memo is kept for the same context and replaced for another' do
        grant(requires_session_flag: 'mfa_verified')
        person = reader

        with_mfa = in_context(session_flags: ['mfa_verified']) { person.permissions_hash }
        assert with_mfa.dig(:permissions, :resources, :Customer, :permissions, :delete_access)
        # another request detail that no condition looks at: the same hash, the same object
        in_context(session_flags: ['mfa_verified'], ip: '1.2.3.4') { assert_same with_mfa, person.permissions_hash }

        without = in_context(session_flags: []) { person.permissions_hash }
        refute_same with_mfa, without
        assert_not without.dig(:permissions, :resources, :Customer, :permissions, :delete_access)

        in_context(session_flags: ['mfa_verified']) { assert person.can_delete?(:Customer) }
      end

      test 'the same context on the same instance costs no store read and returns the same object' do
        grant(requires_session_flag: 'mfa_verified')
        person = reader
        first = in_context(session_flags: ['mfa_verified']) { person.permissions_hash }
        reads = @store.reads

        in_context(session_flags: ['mfa_verified']) { 5.times { assert_same first, person.permissions_hash } }

        assert_equal reads, @store.reads
      end

      test 'a user that holds a variant survives Marshal, and the copy follows the context too' do
        grant(requires_session_flag: 'mfa_verified')
        person = reader
        in_context(session_flags: ['mfa_verified']) { person.permissions_hash }

        copy = Marshal.load(Marshal.dump(person))
        copy.instance_variable_set(:@_pf_permissions_memo,
                                   Marshal.load(Marshal.dump(person.instance_variable_get(:@_pf_permissions_memo))))

        in_context(session_flags: ['mfa_verified']) { assert copy.can_delete?(:Customer) }
        in_context(session_flags: []) { assert_not copy.can_delete?(:Customer) }
      end

      # --- what it costs ------------------------------------------------------------------

      test 'a user without conditional sets reads the store once and never calls the resolver' do
        unconditional_grant
        reader.regenerate_permissions
        person = reader
        reads = @store.reads
        @resolver_calls = 0

        5.times { assert person.can_delete?(:Customer) }

        assert_equal reads + 1, @store.reads
        assert_equal 0, @resolver_calls
        assert_equal PUBLIC_KEYS, PermissionForge.cache.read(@user.permission_cache_key).keys, 'the entry as it always was'
        assert_empty variant_keys
      end

      test 'a user with conditional sets reads the base and the variant once per instance, the base alone when nothing passes' do
        grant(requires_session_flag: 'mfa_verified')
        in_context(session_flags: ['mfa_verified']) { reader.regenerate_permissions }

        reads = @store.reads
        in_context(session_flags: ['mfa_verified']) { person = reader and 5.times { person.can_delete?(:Customer) } }
        assert_equal reads + 2, @store.reads, 'the base and the variant'

        reads = @store.reads
        in_context(session_flags: []) { person = reader and 5.times { person.can_delete?(:Customer) } }
        assert_equal reads + 1, @store.reads, 'the base alone'
      end

      test 'the base and the variant of a user with conditional sets are written with the conditional TTL' do
        grant(requires_session_flag: 'mfa_verified')
        in_context(session_flags: ['mfa_verified']) { reader.regenerate_permissions }

        ttls = @store.writes.reject { |name, _| name.end_with?('_invalidation') }.to_h
        assert_equal 300, ttls.fetch("pf:#{@user.permission_cache_key}")
        assert_equal [300], ttls.select { |name, _| name.match?(/_c_\h/) }.values
        assert_equal PermissionForge.configuration.cache_ttl + PermissionForge::ConditionalSets::INDEX_TTL_MARGIN,
                     ttls.fetch("pf:#{PermissionForge::ConditionalSets.index_key(@user.permission_cache_key)}"),
                     'the index entry outlives every variant written after it'
      end

      # --- the public hash and the stored entries ----------------------------------------

      test 'permissions_hash and regenerate_permissions keep the three-key format; only the stored base entry carries the conditional sets' do
        grant(requires_session_flag: 'mfa_verified')
        person = reader

        in_context(session_flags: ['mfa_verified']) do
          assert_equal PUBLIC_KEYS, person.regenerate_permissions.keys
          assert_equal PUBLIC_KEYS, person.permissions_hash.keys
        end
        in_context(session_flags: []) { assert_equal PUBLIC_KEYS, reader.permissions_hash.keys }

        base = PermissionForge.cache.read(person.permission_cache_key)
        assert_equal PUBLIC_KEYS + [:conditional_sets], base.keys
        assert_nil base.dig(:permissions, :resources, :Customer), 'the base holds the unconditional sets only'
        assert_equal [{ id: @conditional.id, muting: false, requires_session_flag: 'mfa_verified', allowed_ips: nil,
                        allowed_hours_start: nil, allowed_hours_end: nil }], base.dig(:conditional_sets, :sets)
        assert_kind_of String, base.dig(:conditional_sets, :token)

        assert_equal 1, variant_keys.size
        assert variant_keys.first.start_with?("pf:#{person.permission_cache_key}_c_"), 'derived from the (tenant) base key'
        variant = cached(variant_keys.first)
        # Q9: the stored variant carries the digest of the base and the selection it was built for (was the key)
        assert_equal PUBLIC_KEYS + [:variant_of], variant.keys
        assert_equal PermissionForge::ConditionalSets.fingerprint(base.dig(:conditional_sets, :token), [@conditional.id]),
                     variant[:variant_of]
        assert variant.dig(:permissions, :resources, :Customer, :permissions, :delete_access)
      end

      test 'an entry written without conditional sets (an older version of the gem) is served as it is' do
        PermissionForge.cache.write(@user.permission_cache_key, sentinel_entry(read_access: true))

        in_context(session_flags: ['x']) { assert reader.can_read?(:Customer) }

        assert_equal 0, @resolver_calls
      end

      # --- invalidation ---------------------------------------------------------------------

      test 'an admin change invalidates every variant: the next read in each context sees it' do
        grant(requires_session_flag: 'mfa_verified')
        in_context(session_flags: ['mfa_verified']) { assert reader.can_delete?(:Customer) }
        in_context(session_flags: []) { assert_not reader.can_delete?(:Customer) }

        @conditional_resource.update!(delete_access: false)

        in_context(session_flags: ['mfa_verified']) { assert_not reader.can_delete?(:Customer), 'the old variant was served' }
        # Q9: the new variant is written over the old one's slot (was: under a new key)
        token = PermissionForge.cache.read(@user.permission_cache_key).dig(:conditional_sets, :token)
        assert_equal [PermissionForge::ConditionalSets.fingerprint(token, [@conditional.id])],
                     variant_keys.map { |key| cached(key)[:variant_of] }, 'built under the token of the new base entry'
      end

      # Q9: a slot is shared by the variants of every base entry of the key;
      # only the one built for the current base and selection is served.
      test 'a slot that holds the variant of another base entry is a miss: rebuilt, never served' do
        grant(requires_session_flag: 'mfa_verified', delete_access: false)
        in_context(session_flags: ['mfa_verified']) { assert_not reader.can_delete?(:Customer) }
        key = variant_keys.sole
        current = cached(key)[:variant_of]
        forged = cached(key).merge(variant_of: PermissionForge::ConditionalSets.fingerprint('another-base', [@conditional.id]))
        forged[:permissions][:resources][:Customer][:permissions][:delete_access] = true
        PermissionForge.cache.write(key.delete_prefix('pf:'), forged)

        in_context(session_flags: ['mfa_verified']) { assert_not reader.can_delete?(:Customer), 'the variant of another base was served' }
        assert_equal current, cached(key)[:variant_of], 'rebuilt and written over'
      end

      test 'a revoked assignment stops granting in the context that passed' do
        grant(requires_session_flag: 'mfa_verified')
        in_context(session_flags: ['mfa_verified']) { assert reader.can_delete?(:Customer) }

        @assignment.destroy!

        in_context(session_flags: ['mfa_verified']) { assert_not reader.can_delete?(:Customer) }
      end

      test 'invalidate_permissions on one instance retires the variant memoized by another' do
        grant(requires_session_flag: 'mfa_verified')
        person = reader
        in_context(session_flags: ['mfa_verified']) { person.permissions_hash }
        @conditional_resource.update_columns(delete_access: false)

        reader.invalidate_permissions

        in_context(session_flags: ['mfa_verified']) { assert_not person.can_delete?(:Customer) }
      end

      # A commit lands between the rows a variant build read and its write to
      # the store: the pre-commit variant must not stay there (Cache::Rebuild
      # verifies a variant against the same per-user stamp as the base).
      test 'a variant built across an invalidation is not kept in the cache' do
        grant(requires_session_flag: 'mfa_verified')
        in_context(session_flags: []) { reader.permissions_hash }
        resource = @conditional_resource
        writes = 0
        cache = PermissionForge.cache
        cache.define_singleton_method(:write) do |key, value, **options|
          resource.update!(delete_access: false) if key.match?(/_c_\h/) && (writes += 1) == 1
          super(key, value, **options)
        end

        returned = in_context(session_flags: ['mfa_verified']) { reader.permissions_hash }

        assert_equal 2, writes, 'the variant was built once more'
        assert_not returned.dig(:permissions, :resources, :Customer, :permissions, :delete_access)
        stored = variant_keys.filter_map { |key| cached(key) }
        assert_equal 1, stored.size, 'the variant built from the committed rows is cached'
        assert stored.none? { |entry| entry.dig(:permissions, :resources, :Customer, :permissions, :delete_access) },
               'a pre-commit variant survived the invalidation'
      ensure
        cache.singleton_class.send(:remove_method, :write) if cache
      end

      # --- inside a transaction that reads from a snapshot ---------------------------------

      test 'inside a withholding transaction nothing is stored and the instance still follows the context' do
        PermissionForge.configuration.snapshot_transactions = true
        grant(requires_session_flag: 'mfa_verified')
        person = reader

        ActiveRecord::Base.transaction do
          in_context(session_flags: ['mfa_verified']) { assert person.can_delete?(:Customer) }
          in_context(session_flags: []) { assert_not person.can_delete?(:Customer) }
          in_context(session_flags: ['mfa_verified']) { assert person.can_delete?(:Customer) }
          assert_empty hash_keys
        end
        assert_empty hash_keys

        in_context(session_flags: ['mfa_verified']) { assert reader.can_delete?(:Customer) }
        assert_equal 1, variant_keys.size
      end

      test 'with snapshot transactions off a transaction changes nothing: base and variant are cached' do
        PermissionForge.configuration.snapshot_transactions = false
        grant(requires_session_flag: 'mfa_verified')

        ActiveRecord::Base.transaction do
          in_context(session_flags: ['mfa_verified']) { assert reader.can_delete?(:Customer) }
        end

        assert_not_nil PermissionForge.cache.read(@user.permission_cache_key)
        assert_equal 1, variant_keys.size
      end

      # --- audit ---------------------------------------------------------------------------

      test 'a variant rebuilt read-through is published as a read-through rebuild' do
        grant(requires_session_flag: 'mfa_verified')
        in_context(session_flags: []) { reader.permissions_hash }

        payloads = published('permissions.rebuilt') do
          in_context(session_flags: ['mfa_verified']) { reader.permissions_hash }
        end

        assert_equal([{ 'read_through' => true, 'withheld' => false }], payloads.map { |payload| payload[:data] })
      end

      # --- strict mode (WS4-m1, probe X1) ---------------------------------------------------

      test 'X1: in strict mode a blank context drops conditional granting sets and keeps conditional muting sets' do
        PermissionForge.configuration.conditional_sets_strict_mode = true
        unconditional_grant
        mute(requires_session_flag: 'lockdown_exempt_never')
        grant(requires_session_flag: 'mfa_verified', delete_access: false, create_access: true)

        in_context({}) do
          person = reader
          assert person.can_read?(:Customer), 'the unconditional grant'
          assert_not person.can_delete?(:Customer), 'the conditional muting set applies without a context'
          assert_not person.can_create?(:Customer), 'the conditional granting set is dropped without a context'
        end
      end

      test 'in strict mode a present context decides per set, muting sets included' do
        PermissionForge.configuration.conditional_sets_strict_mode = true
        unconditional_grant
        mute(requires_session_flag: 'lockdown')

        in_context(session_flags: ['lockdown']) { assert_not reader.can_delete?(:Customer) }
        in_context(session_flags: ['other']) { assert reader.can_delete?(:Customer) }
      end

      test 'without strict mode a blank context lets a conditional muting set apply as before' do
        unconditional_grant
        mute(requires_session_flag: 'lockdown_exempt_never')

        in_context({}) { assert_not reader.can_delete?(:Customer) }
      end

      # --- what an invalidation removes (review MAJOR-1, probe R15) ----------------------

      # Q9 (was: "invalidate_permissions removes every cached variant along
      # with the base entries"). An invalidation removes the base entries
      # only: the variants it leaves cannot be reached — no base entry
      # carries their token any more — and expire with
      # conditional_set_cache_ttl or are written over. Erasure and
      # cache:clear remove them (below, and PermissionCacheClearerTest).
      test 'invalidate_permissions removes the base entries; the variants it leaves are never served again' do
        grant(requires_session_flag: 'mfa_verified')
        in_context(session_flags: ['mfa_verified']) { reader.permissions_hash }
        in_context(session_flags: []) { reader.permissions_hash }
        assert_equal 1, variant_keys.size
        @conditional_resource.update_columns(delete_access: false) # a change no callback reports

        reader.invalidate_permissions

        assert_nil PermissionForge.cache.read(@user.permission_cache_key), 'the base entry'
        assert_equal 1, variant_keys.size, 'the variant is left to its TTL'
        in_context(session_flags: ['mfa_verified']) { assert_not reader.can_delete?(:Customer), 'the variant left behind was served' }
      end

      test 'R15: DataSubjectErasure leaves no variant behind and reports the cache cleared' do
        PermissionForge.configuration.conditional_set_cache_ttl = nil
        grant(requires_session_flag: 'mfa_verified')
        office = create_permission_set(name: 'Office', allowed_ips: '10.0.0.0/8')
        create_permission_set_user(user: @user, permission_set: office)
        create_resource(permission_set: office, name: 'Customer', read_access: true, create_access: true)
        in_context(session_flags: ['mfa_verified'], ip: '10.0.0.1') { reader.permissions_hash }
        in_context(session_flags: ['mfa_verified'], ip: '203.0.113.1') { reader.permissions_hash }
        assert_equal 2, variant_keys.size

        result = PermissionForge::Services::DataSubjectErasure.call(user: reader)

        assert_equal true, result[:cache_cleared]
        assert_empty hash_keys, "the person's profile stayed in a variant"
      end

      # Q9: every variant of a base key is in one of its slots, whatever base
      # (token) it was built for — those an earlier invalidation left, and
      # those of a base replaced without one — so erasure removes them all.
      test 'DataSubjectErasure removes the variants of every earlier base entry too' do
        PermissionForge.configuration.conditional_set_cache_ttl = nil
        grant(requires_session_flag: 'mfa_verified')
        office = create_permission_set(name: 'Office', allowed_ips: '10.0.0.0/8')
        create_permission_set_user(user: @user, permission_set: office)
        create_resource(permission_set: office, name: 'Customer', read_access: true, create_access: true)
        in_context(session_flags: ['mfa_verified'], ip: '10.0.0.1') { reader.permissions_hash }
        reader.invalidate_permissions
        in_context(session_flags: ['mfa_verified'], ip: '203.0.113.1') { reader.permissions_hash }
        in_context(session_flags: [], ip: '10.0.0.1') { reader.regenerate_permissions } # a new base, no invalidation
        assert_equal 3, variant_keys.size, 'precondition: variants of three bases'

        result = PermissionForge::Services::DataSubjectErasure.call(user: reader)

        assert_equal true, result[:cache_cleared]
        assert_empty hash_keys, "the person's profile stayed in a variant"
      end

      # Q9 review F-1: Redis, Memcached and Solid Cache stores answer a read
      # that failed with "nothing", and the store may evict the index entry.
      # Erasure does not rely on the index: it removes every slot of each of
      # the person's base keys.
      test 'DataSubjectErasure removes the variants without reading the index entry (a read that fails silently, an evicted index)' do
        grant(requires_session_flag: 'mfa_verified')
        cache = PermissionForge.cache
        cache.define_singleton_method(:read_many) { |keys| keys.to_h { |key| [key, nil] } } # a failed read, swallowed

        in_context(session_flags: ['mfa_verified']) { reader.permissions_hash }
        result = PermissionForge::Services::DataSubjectErasure.call(user: reader)
        assert_equal true, result[:cache_cleared]
        assert_empty hash_keys, "the person's profile stayed in a variant (silent read failure)"

        cache.singleton_class.send(:remove_method, :read_many)
        @assignment = create_permission_set_user(user: @user, permission_set: @conditional)
        in_context(session_flags: ['mfa_verified']) { reader.permissions_hash }
        PermissionForge.cache.delete(PermissionForge::ConditionalSets.index_key(@user.permission_cache_key)) # evicted
        assert_equal 1, variant_keys.size, 'precondition: a variant whose index entry is gone'

        PermissionForge::Services::DataSubjectErasure.call(user: reader)

        assert_empty hash_keys, "the person's profile stayed in a variant (evicted index)"
      ensure
        cache.singleton_class.send(:remove_method, :read_many) if cache&.singleton_class&.method_defined?(:read_many, false)
      end

      test 'DataSubjectErasure reports the cache not cleared when the store does not confirm the removal of a variant' do
        grant(requires_session_flag: 'mfa_verified')
        in_context(session_flags: ['mfa_verified']) { reader.permissions_hash }
        cache = PermissionForge.cache
        cache.define_singleton_method(:expunge) { |key| key.include?('_c_') ? false : super(key) }

        result = PermissionForge::Services::DataSubjectErasure.call(user: reader)

        assert_equal false, result[:cache_cleared]
      ensure
        cache&.singleton_class&.send(:remove_method, :expunge)
      end

      # Inside the caller's transaction the rows are only gone for everybody
      # else at the commit: a request may cache a variant before it. The
      # variants are removed once the transaction has committed.
      test 'DataSubjectErasure inside a transaction removes the variants once it has committed' do
        grant(requires_session_flag: 'mfa_verified')
        in_context(session_flags: ['mfa_verified']) { reader.permissions_hash }
        key = @user.permission_cache_key
        late = "#{key}_c_1"

        ActiveRecord::Base.transaction do
          PermissionForge::Services::DataSubjectErasure.call(user: reader)
          # another request, still reading the rows as they were, caches a variant
          PermissionForge.cache.write(PermissionForge::ConditionalSets.index_key(key), true)
          PermissionForge.cache.write(late, sentinel_entry(delete_access: true))
          assert_not_nil PermissionForge.cache.read(late), 'not before the commit'
        end

        assert_empty hash_keys, "the person's profile stayed in a variant"
      end

      test 'above MAX_CACHED_SETS conditional sets a variant is built for the request, never stored nor looked for' do
        (PermissionForge::ConditionalSets::MAX_CACHED_SETS + 1).times { |i| grant(requires_session_flag: "flag_#{i}") }
        person = reader

        in_context(session_flags: %w[flag_0 flag_3]) do
          assert person.can_delete?(:Customer)
          assert_same person.permissions_hash, person.permissions_hash, 'memoized for the request'
        end

        assert_not_nil PermissionForge.cache.read(@user.permission_cache_key), 'the base entry is cached'
        assert_empty variant_keys, 'a variant was stored'
        reads = @store.reads
        in_context(session_flags: %w[flag_0 flag_3]) { assert reader.can_delete?(:Customer) }
        assert_equal reads + 1, @store.reads, 'the base alone: a variant that is never stored is not read (N4)'
        in_context(session_flags: []) { assert_not reader.can_delete?(:Customer) }
        reader.invalidate_permissions
        assert_empty hash_keys
      end

      # --- strict mode with the documented resolver (review MAJOR-2, probe R3) -------------

      test 'R3: in strict mode the documented resolver in a job counts as no context: the lockdown applies, the grant is dropped' do
        PermissionForge.configuration.conditional_sets_strict_mode = true
        unconditional_grant
        mute(allowed_ips: '192.0.2.0/24')
        grant(requires_session_flag: 'mfa_verified', delete_access: false, create_access: true)

        in_context(ip: nil, session_flags: [], time: Time.current) do
          person = reader
          assert_not person.can_delete?(:Customer), 'the IP-gated lockdown applies without a request'
          assert_not person.can_create?(:Customer), 'the flag-gated grant is dropped without a request'
        end
        in_context(ip: '192.0.2.7', session_flags: ['mfa_verified'], time: Time.current) do
          person = reader
          assert_not person.can_delete?(:Customer), 'from the kiosk range the lockdown applies'
          assert person.can_create?(:Customer)
        end
        in_context(ip: '10.0.0.7', session_flags: [], time: Time.current) do
          person = reader
          assert person.can_delete?(:Customer), 'from elsewhere it does not'
          assert_not person.can_create?(:Customer)
        end
      end

      test 'without strict mode the documented resolver in a job is evaluated per set, as before' do
        unconditional_grant
        mute(allowed_ips: '192.0.2.0/24')
        grant(requires_session_flag: 'mfa_verified', delete_access: false, create_access: true)
        hours = create_permission_set(name: 'Hours', allowed_hours_start: 9, allowed_hours_end: 17)
        create_permission_set_user(user: @user, permission_set: hours)
        create_resource(permission_set: hours, name: 'Customer', read_access: true, edit_access: true)

        in_context(ip: nil, session_flags: [], time: Time.current.change(hour: 12)) do
          person = reader
          assert person.can_delete?(:Customer), 'an IP condition that cannot be checked fails: the lockdown does not apply'
          assert_not person.can_create?(:Customer), 'no MFA grant in a job'
          assert person.can_edit?(:Customer), 'the hours are checked'
        end
        in_context(ip: nil, session_flags: [], time: Time.current.change(hour: 20)) do
          assert_not reader.can_edit?(:Customer)
        end
      end

      test 'in strict mode session flags alone are a request context, evaluated per set' do
        PermissionForge.configuration.conditional_sets_strict_mode = true
        unconditional_grant
        mute(allowed_ips: '192.0.2.0/24')
        grant(requires_session_flag: 'mfa_verified', delete_access: false, create_access: true)

        in_context(session_flags: ['mfa_verified']) do
          person = reader
          assert person.can_create?(:Customer)
          assert_not person.can_delete?(:Customer), 'an IP lockdown cannot be judged without an IP: it applies (CS-3)'
        end
      end

      # --- races (review MINOR-1, probe R1b; MINOR-4, probe R2) -----------------------------

      test 'R1b: a condition tightened while a variant is built is seen by the same instance on its next read' do
        grant(requires_session_flag: 'mfa_verified')
        in_context(session_flags: []) { reader.permissions_hash }
        set = @conditional
        person = reader
        cache = PermissionForge.cache
        fired = false
        cache.define_singleton_method(:write) do |key, value, **options|
          if key.include?('_c_') && !fired
            fired = true
            set.update!(requires_session_flag: 'hardware_key')
          end
          super(key, value, **options)
        end
        in_context(session_flags: ['mfa_verified']) { person.can_delete?(:Customer) }
        cache.singleton_class.send(:remove_method, :write)

        assert_not in_context(session_flags: ['mfa_verified']) { person.can_delete?(:Customer) },
                   'the memo outlived the invalidation'
        assert_not in_context(session_flags: ['mfa_verified']) { reader.can_delete?(:Customer) }
      ensure
        cache.singleton_class.send(:remove_method, :write) if cache&.singleton_methods&.include?(:write)
      end

      test 'R2: the memo is selected by the hour the conditions were checked at, not by a later one' do
        grant(allowed_hours_start: 9, allowed_hours_end: 17)
        evaluator = PermissionForge::Services::PermissionSetConditionEvaluator
        evaluator.singleton_class.alias_method(:original_call, :call)
        moved = false
        test = self
        evaluator.define_singleton_method(:call) do |**options|
          result = original_call(**options)
          # the clock passes 17:00 right after the evaluation
          test.travel_to(Time.zone.local(2026, 10, 13, 17, 0, 0)) unless moved
          moved = true
          result
        end
        travel_to Time.zone.local(2026, 10, 13, 16, 59, 59)
        person = reader

        assert in_context(ip: '1.2.3.4') { person.can_delete?(:Customer) }
        replace_method(evaluator.singleton_class, :call, evaluator.singleton_class.instance_method(:original_call))
        travel_to Time.zone.local(2026, 10, 13, 17, 40, 0)

        assert_not in_context(ip: '1.2.3.4') { person.can_delete?(:Customer) }, 'selected by the hour after the evaluation'
      ensure
        if evaluator.singleton_class.method_defined?(:original_call)
          evaluator.singleton_class.alias_method(:call, :original_call)
          evaluator.singleton_class.send(:remove_method, :original_call)
        end
        travel_back
      end

      # --- the resolver (review MINOR-2 / MINOR-3, probes R4 and R14) -----------------------

      test 'R4: a resolver that reads the permissions of the user it resolves for raises instead of being answered' do
        grant(requires_session_flag: 'mfa_verified')
        person = reader
        in_context(session_flags: ['mfa_verified']) { person.permissions_hash }
        PermissionForge.configuration.request_context_resolver = lambda do
          person.can_read?(:Customer)
          { session_flags: ['mfa_verified'] }
        end

        assert_raises(PermissionForge::ConfigurationError) { person.can_delete?(:Customer) } # the memo path
        assert_raises(PermissionForge::ConfigurationError) { reader.can_delete?(:Customer) } # the cold path
      end

      test 'R14: a host override that regenerates on an empty hash keeps working with a resolver that reads no permissions' do
        grant(requires_session_flag: 'mfa_verified')

        in_context(session_flags: ['mfa_verified']) { assert SelfHealingUser.find(@user.id).can_delete?(:Customer) }
        in_context(session_flags: []) { assert_not SelfHealingUser.find(@user.id).can_delete?(:Customer) }
      end

      # --- the entry namespace (review MINOR-5) --------------------------------------------

      test 'the entry key is namespaced, and an invalidation also removes the keys of the previous namespace' do
        unconditional_grant
        namespace = PermissionForge::Cache::UserKeys::ENTRY_NAMESPACE
        key = @user.permission_cache_key
        assert key.start_with?("#{namespace}:"), key
        legacy = key.delete_prefix("#{namespace}:")
        PermissionForge.cache.write(legacy, sentinel_entry(read_access: true))
        reader.permissions_hash

        reader.invalidate_permissions

        assert_nil PermissionForge.cache.read(legacy), 'the key a 0.13 process reads'
        assert_nil PermissionForge.cache.read(key)
      end

      # --- details (review NITs, probes R6, R7, N1 and N5) ----------------------------------

      test 'N1: a memo left by an earlier version (an Array, marshalled with the 6.1 format) is no memo' do
        unconditional_grant
        person = reader
        stale = [person.permission_cache_key, PermissionForge.permissions_cache_version, nil, sentinel_entry(read_access: true)]
        person.instance_variable_set(:@_pf_permissions_memo, stale.freeze)
        format = ActiveRecord.marshalling_format_version
        ActiveRecord.marshalling_format_version = 6.1
        copy = Marshal.load(Marshal.dump(person))
        ActiveRecord.marshalling_format_version = format
        assert_kind_of Array, copy.instance_variable_get(:@_pf_permissions_memo), 'the 6.1 format carries the variable'

        assert copy.can_delete?(:Customer), 'read from the store, not from the Array'
        assert_kind_of PermissionsMemo::Memo, copy.instance_variable_get(:@_pf_permissions_memo)
        assert person.can_delete?(:Customer)
        person.instance_variable_set(:@_pf_permissions_memo, stale.freeze)
        person.invalidate_permissions
        person.reload
        assert person.can_delete?(:Customer)
      ensure
        ActiveRecord.marshalling_format_version = format if format
      end

      test 'N5: a resolver may return a Struct (anything with to_h)' do
        grant(requires_session_flag: 'mfa_verified')
        request = Struct.new(:ip, :session_flags, :time)

        in_context(request.new('10.0.0.1', ['mfa_verified'], nil)) { assert reader.can_delete?(:Customer) }
        in_context(request.new('10.0.0.1', [], nil)) { assert_not reader.can_delete?(:Customer) }
      end

      test 'R7: a flag mutated in place after the memo does not keep the old selection' do
        grant(requires_session_flag: 'mfa_verified')
        flag = +'mfa_verified'
        person = reader

        assert in_context(session_flags: [flag]) { person.can_delete?(:Customer) }
        flag.replace('nope')

        assert_not in_context(session_flags: [flag]) { person.can_delete?(:Customer) }
      end

      test 'R6: a base entry whose conditional sets carry no token is rebuilt, not served' do
        grant(requires_session_flag: 'mfa_verified')
        foreign = sentinel_entry(read_access: true).merge(conditional_sets: { sets: [{ id: @conditional.id }] })
        PermissionForge.cache.write(@user.permission_cache_key, foreign)

        in_context(session_flags: ['mfa_verified']) { assert reader.can_delete?(:Customer) }

        assert_kind_of String, PermissionForge.cache.read(@user.permission_cache_key).dig(:conditional_sets, :token)
      end

      private

      def reader
        User.find(@user.id)
      end

      def grant(**attrs)
        conditions = attrs.slice(:requires_session_flag, :allowed_ips, :allowed_hours_start, :allowed_hours_end)
        @conditional = create_permission_set(name: 'Conditional', **conditions)
        @assignment = create_permission_set_user(user: @user, permission_set: @conditional)
        access = { read_access: true, delete_access: true }.merge(attrs.except(*conditions.keys))
        @conditional_resource = create_resource(permission_set: @conditional, name: 'Customer', **access)
      end

      def mute(**conditions)
        lockdown = create_permission_set(name: 'Lockdown', is_muting: true, **conditions)
        create_permission_set_user(user: @user, permission_set: lockdown)
        create_resource(permission_set: lockdown, name: 'Customer', read_access: false, delete_access: true)
      end

      def unconditional_grant
        plain = create_permission_set(name: 'Plain')
        create_permission_set_user(user: @user, permission_set: plain)
        create_resource(permission_set: plain, name: 'Customer', read_access: true, delete_access: true)
      end

      def abilities(person)
        [person.can_delete?(:Customer), person.can_create?(:Customer)]
      end

      def in_context(context)
        previous = @context
        @context = context
        yield
      ensure
        @context = previous
      end

      def sentinel_entry(**permissions)
        { profile: {}, preferences: {}, permissions: { resources: { Customer: { permissions: permissions } } } }
      end

      def stored_keys
        @store.instance_variable_get(:@data).keys
      end

      # The keys of this user's hashes that hold an entry: the base entry and
      # its variants (not the invalidation stamp, not the managed-actions
      # index, and not the empty entry RailsCache#expunge leaves for a second
      # where there was nothing to remove).
      def hash_keys
        stored_keys.grep(/user_#{@user.id}(_c_|\z)/).select { |name| cached(name) }
      end

      def variant_keys
        stored_keys.grep(/_c_\h/).select { |name| cached(name) }
      end

      # A stored entry as PermissionForge reads it (keys symbolized), by its store name.
      def cached(name)
        PermissionForge.cache.read(name.delete_prefix('pf:'))
      end
    end
  end
end
