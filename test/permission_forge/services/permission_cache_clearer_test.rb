# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

module PermissionForge
  module Services
    # The step after a deploy that changed the cache entries: every user's
    # entries go — this version's, the previous version's, the per-context
    # variants — in every tenant, by key pattern where the store can, else
    # user by user through the bulk invalidation. Review round 3, probes K1
    # (a user a 0.13 pod fully revoked during the deploy) and K2 (one event
    # per tenant).
    class PermissionCacheClearerTest < ActiveSupport::TestCase
      # Its Redis tests write to and flush a database every worker shares.
      include ParallelWorkers::SharedResource
      include LocalRedis

      # A Rails store that cannot remove keys by pattern (Memcached, Solid Cache).
      class NoPatternStore < ActiveSupport::Cache::MemoryStore
        def delete_matched(*) = raise(NotImplementedError)
      end

      # ... and whose removals the gem cannot confirm either (unreachable).
      class UnconfirmingStore < NoPatternStore
        def write(*) = nil
        def delete(*) = nil
      end

      # A store whose delete_matched answers as if it worked and removes
      # nothing (what a pattern the store does not understand amounts to).
      class SilentPatternStore < ActiveSupport::Cache::MemoryStore
        def delete_matched(*) = []
      end

      setup do
        @tenant_b = Account.create!(name: 'Tenant B')
        @holder = create_user(name: 'Holder')
        @revoked = create_user(name: 'Revoked')
        @idle = create_user(name: 'Idle')
        @elsewhere = create_user(name: 'Elsewhere')

        plain = create_permission_set(name: 'Plain')
        create_permission_set_user(user: @holder, permission_set: plain)
        create_resource(permission_set: plain, name: 'Customer', read_access: true)
        mfa = create_permission_set(name: 'MFA', requires_session_flag: 'mfa_verified')
        create_permission_set_user(user: @holder, permission_set: mfa)
        create_resource(permission_set: mfa, name: 'Customer', read_access: true, delete_access: true)

        only = create_permission_set(name: 'Only')
        @revoked_row = create_permission_set_user(user: @revoked, permission_set: only)
        create_resource(permission_set: only, name: 'Customer', read_access: true, delete_access: true)

        in_tenant(@tenant_b) do
          set_b = create_permission_set(name: 'Set B')
          create_permission_set_user(user: @elsewhere, permission_set: set_b)
          create_resource(permission_set: set_b, name: 'Supplier', read_access: true)
        end

        PermissionForge.configuration.request_context_resolver = -> { { session_flags: ['mfa_verified'] } }
      end

      teardown do
        PermissionForge.configuration.request_context_resolver = -> { {} }
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
        PermissionForge.configuration.on_cache_failure = nil
      end

      # --- K1, both strategies -------------------------------------------------------------

      # ActiveSupport puts a store's own namespace in front of the pattern
      # (review round 4, P3/P5): the clear must still reach the keys.
      test 'by pattern on a namespaced MemoryStore: the entries go, and the revoked user is denied' do
        assert_pattern_clear_on(ActiveSupport::Cache::MemoryStore.new(namespace: 'host'))
      end

      test 'by pattern on a namespaced FileStore: the entries go, and the revoked user is denied' do
        Dir.mktmpdir { |dir| assert_pattern_clear_on(ActiveSupport::Cache::FileStore.new(dir, namespace: 'host')) }
      end

      test 'a pattern removal the store only pretends to make is not reported as one: the users are enumerated' do
        PermissionForge.configuration.cache_backend = SilentPatternStore.new
        PermissionForge.configuration.reset_cache_store!
        warm
        revoked_by_an_old_pod

        result = PermissionCacheClearer.call(actor: 'ops')

        assert_equal :enumerated, result[:strategy]
        assert_nothing_left
        assert_not User.find(@revoked.id).can_delete?(:Customer)
      end

      # Q9: an invalidation leaves the variants to their TTL (unreachable);
      # a clear by enumeration finds them through the index entry.
      test 'by enumeration the variants an earlier invalidation left go too' do
        PermissionForge.configuration.cache_backend = NoPatternStore.new
        PermissionForge.configuration.reset_cache_store!
        User.find(@holder.id).permissions_hash
        User.find(@holder.id).invalidate_permissions
        assert_equal 1, keys.grep(/_c_\h/).size, 'precondition: the variant the invalidation left'

        result = PermissionCacheClearer.call(actor: 'ops')

        assert_equal :enumerated, result[:strategy]
        assert_equal 0, result[:unconfirmed]
        assert_nothing_left
      end

      test 'string ids (usr_123, a tenant with an underscore) are matched on memory and file stores; the stamps are not' do
        Dir.mktmpdir do |dir|
          stores = [Cache::MemoryCache.new(prefix: 'pfs'),
                    Cache::RailsCache.new(prefix: 'pfs', store: ActiveSupport::Cache::MemoryStore.new(namespace: 'host')),
                    Cache::RailsCache.new(prefix: 'pfs', store: ActiveSupport::Cache::FileStore.new(dir))]
          stores.each do |cache|
            entries = %w[v2:user_usr_123 v2:tenant_t_9_user_usr_123 v2:tenant_t_9_user_usr_123_c_0123456789abcdef0123456789abcdef
                         user_usr_123 tenant_t_9_user_usr_123]
            kept = %w[user_usr_123_invalidation managed_actions managed_actions_invalidation tenant_t_9_managed_actions]
            (entries + kept).each { |key| cache.write(key, { x: 1 }) }

            assert cache.clear_entries('v2'), cache.class.name
            assert cache.clear_entries(''), cache.class.name

            entries.each { |key| assert_nil cache.read(key), "#{cache.class.name}: #{key} survived" }
            kept.each { |key| assert_equal({ x: 1 }, cache.read(key), "#{cache.class.name}: #{key} was removed") }
          end
        end
      end

      test 'by pattern (a store that matches keys): every entry of every user goes, fully revoked and idle users included' do
        warm
        revoked_by_an_old_pod
        legacy = legacy_key(@holder)
        PermissionForge.cache.write(legacy, sentinel)
        assert_equal 1, keys.grep(/_c_\h/).size, 'precondition: a variant is cached'
        assert_not_nil PermissionForge.cache.read(@idle.permission_cache_key), 'precondition: the idle user has an entry'

        tenants = Account.unscoped.count
        result = PermissionCacheClearer.call(actor: 'ops: TCK-12', reason: 'deploy 0.14')

        assert_equal({ strategy: :pattern, users: nil, tenants: tenants, unconfirmed: 0 }, result)
        assert_nothing_left
        assert_nil PermissionForge.cache.read(legacy)
        assert_not User.find(@revoked.id).can_delete?(:Customer), 'K1: the entry a 0.13 revocation could not reach'
        assert_equal tenants + 1, AuditEvent.unscoped.where(event: 'cache.cleared').count, 'one per tenant, one without'
        assert_audit_event('cache.cleared', actor_type: 'system', actor_label: 'ops: TCK-12', reason: 'deploy 0.14',
                                            data: { 'operation' => 'cache_clear', 'strategy' => 'pattern', 'counted' => false })
        assert_equal({ 'operation' => 'cache_clear', 'strategy' => 'pattern', 'counted' => false, 'unconfirmed' => 0,
                       'tenants' => tenants, 'across_tenants' => true, 'process_local' => true }, tenantless_event.data)
      end

      test 'by enumeration (a store without delete_matched): every user, once per tenant and once without, through the bulk path' do
        PermissionForge.configuration.cache_backend = NoPatternStore.new
        PermissionForge.configuration.reset_cache_store!
        warm
        revoked_by_an_old_pod
        legacy = legacy_key(@holder)
        PermissionForge.cache.write(legacy, sentinel)
        assert Cache::HolderInvalidation.by_id?(User), 'precondition: the bulk path applies'
        everyone = User.unscoped.count
        tenants = Account.unscoped.count

        result = PermissionCacheClearer.call(actor: 'ops: TCK-12', reason: 'deploy 0.14')

        assert_equal :enumerated, result[:strategy]
        assert_equal tenants, result[:tenants]
        # the dummy User is not tenant-scoped: visited under each tenant, and once without
        assert_equal everyone * (tenants + 1), result[:users]
        assert_equal 0, result[:unconfirmed]
        assert_nothing_left
        assert_nil PermissionForge.cache.read(legacy)
        assert_not User.find(@revoked.id).can_delete?(:Customer), 'K1 under enumeration'
        assert_audit_event('cache.cleared', data: { 'strategy' => 'enumerated', 'users' => everyone, 'unconfirmed' => 0 })
        assert_equal({ 'operation' => 'cache_clear', 'strategy' => 'enumerated', 'users' => everyone * (tenants + 1),
                       'tenants' => tenants,
                       'unconfirmed' => 0, 'across_tenants' => true, 'process_local' => true }, tenantless_event.data)
      end

      test 'enumeration goes through each user\'s own invalidate_permissions where the bulk path must not be used' do
        PermissionForge.configuration.cache_backend = NoPatternStore.new
        PermissionForge.configuration.reset_cache_store!
        warm
        called = []
        User.define_method(:invalidate_permissions) do |**options|
          called << [id, options[:tenant_id]]
          super(**options)
        end
        assert_not Cache::HolderInvalidation.by_id?(User)

        result = PermissionCacheClearer.call(actor: 'ops')

        assert_equal :enumerated, result[:strategy]
        assert_equal result[:users], called.size
        assert_includes called, [@elsewhere.id, @tenant_b.id]
        assert_nothing_left
      ensure
        User.send(:remove_method, :invalidate_permissions)
      end

      # --- K2: the events ----------------------------------------------------------------------

      test 'K2: one cache.cleared event per tenant, visible in that tenant\'s log, plus one without a tenant' do
        PermissionForge.configuration.cache_backend = NoPatternStore.new
        PermissionForge.configuration.reset_cache_store!
        warm

        PermissionCacheClearer.call(actor: 'ops', reason: 'deploy 0.14')

        column = AuditEvent.tenant_column
        events = AuditEvent.unscoped.where(event: 'cache.cleared').order(:id).to_a
        assert_equal(Account.unscoped.order(:id).pluck(:id) + [nil], events.map { |event| event.read_attribute(column) })
        in_tenant(@tenant_b) do
          visible = AuditEvent.where(event: 'cache.cleared').to_a
          assert_equal 1, visible.size, "tenant B's auditors see their event"
          assert_equal User.unscoped.count, visible.first.data['users']
          assert_nil visible.first.data['across_tenants']
        end
        assert_equal true, events.last.data['across_tenants']
      end

      # --- the rest ------------------------------------------------------------------------

      test 'the next read rebuilds for the context that reads' do
        warm
        PermissionCacheClearer.call(actor: 'ops')

        assert User.find(@holder.id).can_delete?(:Customer)
        PermissionForge.configuration.request_context_resolver = -> { { session_flags: [] } }
        assert_not User.find(@holder.id).can_delete?(:Customer)
      end

      test 'what the store does not confirm is counted, and reported' do
        PermissionForge.configuration.cache_backend = UnconfirmingStore.new
        PermissionForge.configuration.reset_cache_store!
        reported = []
        PermissionForge.configuration.on_cache_failure = ->(failure) { reported << failure[:user_id] }

        result = PermissionCacheClearer.call(actor: 'ops')

        assert_equal :enumerated, result[:strategy]
        assert_equal result[:users], result[:unconfirmed]
        assert_equal User.unscoped.pluck(:id).sort, reported.uniq.sort
      end

      test 'a Redis store removes the entries of a namespace by glob and leaves other keys alone' do
        cache = redis_cache
        entries = %w[v2:user_9 v2:tenant_1_user_9 v2:tenant_1_user_9_c_0123456789abcdef0123456789abcdef user_9 tenant_1_user_9
                     v2:user_usr_123 v2:tenant_t_9_user_usr_123 user_usr_123]
        entries.each { |key| cache.write(key, sentinel) }
        cache.write('tenant_1_managed_actions', { x: 1 })
        cache.write('user_9_invalidation', 'stamp')

        assert cache.clear_entries('v2')
        assert cache.clear_entries('')

        entries.each { |key| assert_nil cache.read(key), "#{key} survived" }
        assert_equal({ x: 1 }, cache.read('tenant_1_managed_actions'), 'the managed-actions index is not a permission entry')
        assert_nil cache.read('user_9_invalidation'), 'a glob cannot spare the stamp: documented'
      ensure
        cache&.clear
      end

      test 'a Rails store without delete_matched answers false and removes nothing' do
        cache = Cache::RailsCache.new(prefix: 'pfx', store: NoPatternStore.new)
        cache.write('v2:user_9', sentinel)

        assert_not cache.clear_entries('v2')
        assert_equal sentinel, cache.read('v2:user_9')
      end

      private

      def warm
        [@holder, @revoked, @idle].each { |user| User.find(user.id).permissions_hash }
        in_tenant(@tenant_b) { User.find(@elsewhere.id).permissions_hash }
      end

      # K1: a 0.13 pod destroyed the user's last row and invalidated the bare
      # keys only; the v2: entry still grants.
      def revoked_by_an_old_pod
        assert User.find(@revoked.id).can_delete?(:Customer)
        PermissionForge::PermissionSetUser.where(id: @revoked_row.id).delete_all
        Cache::Invalidation.call(**old_pod_invalidation(@revoked.id))
        assert User.find(@revoked.id).can_delete?(:Customer), 'precondition: the v2 entry still grants'
      end

      # What a 0.13 process removes: the bare keys, under its own stamp.
      def old_pod_invalidation(user_id)
        bare = ["user_#{user_id}", "tenant_#{PermissionForge.ambient_tenant_id}_user_#{user_id}"]
        { user_id: user_id, stamp_key: "user_#{user_id}_invalidation", keys: bare }
      end

      def assert_pattern_clear_on(store)
        PermissionForge.configuration.cache_backend = store
        PermissionForge.configuration.reset_cache_store!
        warm
        revoked_by_an_old_pod
        store.write('views/user_1', 'host')

        result = PermissionCacheClearer.call(actor: 'ops')

        assert_equal :pattern, result[:strategy]
        assert_entries_cleared
        assert_equal 'host', store.read('views/user_1'), 'a host key is not a permission entry'
      end

      def assert_entries_cleared
        assert_nil PermissionForge.cache.read(@revoked.permission_cache_key), 'the entry survived'
        assert_nil PermissionForge.cache.read(@holder.permission_cache_key)
        assert_not User.find(@revoked.id).can_delete?(:Customer)
      end

      # The raw keys of whatever store PermissionForge.cache wraps, where it
      # keeps them in memory; a file store is checked through reads instead.
      def assert_nothing_left
        return if PermissionForge.cache.instance_variable_get(:@store).is_a?(ActiveSupport::Cache::FileStore)

        [@holder, @revoked, @idle, @elsewhere].each do |user|
          assert_empty keys.grep(/user_#{user.id}(_c_|\z)/).select { |key| PermissionForge.cache.read(key.sub(/\A\w+:/, '')) },
                       "#{user.name} still has an entry"
        end
      end

      # The event recorded with no tenant, which a tenant's log never shows.
      test 'every event says whether the clear reached only this process (a memory store) or a shared store' do
        PermissionCacheClearer.call(actor: 'ops')

        events = AuditEvent.unscoped.where(event: 'cache.cleared').to_a
        assert events.any?
        assert(events.all? { |event| event.data['process_local'] == true }, 'the suite\'s memory store lives in this process')

        Dir.mktmpdir do |dir|
          PermissionForge.configuration.cache_backend = ActiveSupport::Cache::FileStore.new(dir)
          PermissionForge.configuration.reset_cache_store!
          before = AuditEvent.unscoped.maximum(:id)

          PermissionCacheClearer.call(actor: 'ops')

          shared = AuditEvent.unscoped.where(event: 'cache.cleared').where('id > ?', before).to_a
          assert shared.any?
          assert(shared.all? { |event| event.data['process_local'] == false }, 'a file store is shared by the processes')
        end
      end

      def tenantless_event
        column = AuditEvent.tenant_column
        AuditEvent.unscoped.where(event: 'cache.cleared').order(:id).to_a.find { |event| event.read_attribute(column).nil? }
      end

      def legacy_key(user)
        user.permission_cache_key.delete_prefix("#{Cache::UserKeys::ENTRY_NAMESPACE}:")
      end

      def sentinel
        { profile: {}, preferences: {}, permissions: { resources: { Customer: { permissions: { read_access: true } } } } }
      end

      # The raw keys of whatever store PermissionForge.cache wraps.
      def keys
        cache = PermissionForge.cache
        store = cache.instance_variable_get(:@store)
        (store.is_a?(Hash) ? store : store.instance_variable_get(:@data)).keys
      end

      def redis_cache
        require_local_redis!
        Cache::RailsCache.new(prefix: 'pfclear', store: ActiveSupport::Cache::RedisCacheStore.new(url: LocalRedis::URL, pool: false))
      end

      def in_tenant(tenant)
        previous = ActsAsTenant.test_tenant
        ActsAsTenant.test_tenant = tenant
        yield
      ensure
        ActsAsTenant.test_tenant = previous
      end
    end
  end
end
