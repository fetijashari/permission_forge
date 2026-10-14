# frozen_string_literal: true

require 'test_helper'
require_relative 'failing_store'

module PermissionForge
  module Cache
    # Many invalidations in one go: the multi-key calls of the cache
    # backends (Base#write_many / #expunge_many), BulkInvalidation (stamps
    # first, every answer checked, failures reported and owed) and
    # HolderInvalidation (the holders of a changed set, by id, in slices).
    # A change to a set with 10,000 holders cost 30,000 store calls and
    # 20,000 loaded records in the saving request (pre-release performance review
    # MAJOR-2).
    class BulkInvalidationTest < ActiveSupport::TestCase
      # Its Redis tests write to and flush a database every worker shares.
      include ParallelWorkers::SharedResource

      REDIS_URL = 'redis://127.0.0.1:6379/15'

      # A subclass of the user model (STI in a host); overrides nothing
      # unless a test gives it a method.
      class SubclassedUser < ::User; end

      setup do
        @reported = []
        PermissionForge.configuration.on_cache_failure = ->(**failure) { @reported << failure }
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      # --- the multi-key calls -------------------------------------------------------

      test 'Base answers per key, one call each, and tries every key when one raises' do
        cache = MemoryCache.new(prefix: 'pfbulk')
        cache.write('b', 1)
        def cache.write(key, value, ttl: nil)
          raise 'broken key' if key == 'bad'

          super
        end
        errors = []

        written = cache.write_many({ 'a' => 1, 'bad' => 2, 'c' => 3 }, ttl: 60) { |error| errors << error.message }
        removed = cache.expunge_many(%w[b missing])

        assert_equal({ 'a' => true, 'bad' => false, 'c' => true }, written)
        assert_equal ['broken key'], errors
        assert_equal 3, cache.read('c')
        assert_equal({ 'b' => true, 'missing' => true }, removed)
        assert_nil cache.read('b')
      end

      test 'a store without a multi-write of its own is written key by key, each answer kept' do
        store = FailingStore.new
        store.fail_when = ->(operation, key) { operation == :write && key == 'bad' }
        cache = RailsCache.new(store: store)

        written = cache.write_many({ 'good' => 1, 'bad' => 2 }, ttl: 60)
        cache.write('there', 1)
        removed = cache.expunge_many(%w[there bad])

        assert_equal({ 'good' => true, 'bad' => false }, written)
        assert removed['there']
        assert_not removed['bad'], 'a delete that found nothing and an empty entry the store refused'
        assert_nil cache.read('there')
      end

      test 'Redis gets every entry in one round trip, and an expunged key is gone from the request copy too' do
        store = redis_store
        cache = RailsCache.new(prefix: "pfbulk#{SecureRandom.hex(3)}", store: store)
        calls = store_calls do
          assert_equal({ 'a' => true, 'b' => true }, cache.write_many({ 'a' => 'x', 'b' => 'y' }, ttl: 60))
        end
        assert_equal ['cache_write_multi.active_support'], calls

        store.with_local_cache do
          assert_equal 'x', cache.read('a') # the request now holds a copy
          calls = store_calls { assert_equal({ 'a' => true, 'b' => true }, cache.expunge_many(%w[a b])) }

          assert_equal ['cache_write_multi.active_support'], calls
          assert_nil cache.read('a'), 'the request copy is replaced, not left behind'
        end
        assert_nil cache.read('b')
      ensure
        store&.clear
      end

      test 'a Redis that cannot be reached answers false for every key, without raising' do
        store = redis_store(url: 'redis://127.0.0.1:1/15')
        cache = RailsCache.new(store: store)

        assert_equal({ 'a' => false, 'b' => false }, cache.write_many({ 'a' => 1, 'b' => 2 }))
        assert_equal({ 'a' => false }, cache.expunge_many(%w[a]))
      end

      test 'a store that is not an ActiveSupport store is written key by key' do
        store = SimpleDelegator.new(ActiveSupport::Cache::MemoryStore.new)
        cache = RailsCache.new(store: store)
        cache.write('there', 1)

        assert_equal({ 'a' => true }, cache.write_many({ 'a' => 1 }))
        assert_equal({ 'there' => true }, cache.expunge_many(%w[there]))
        assert_nil cache.read('there')
      end

      # --- BulkInvalidation ----------------------------------------------------------

      test 'the keys are removed even when writing the stamps raises as a whole' do
        cache = MemoryCache.new(prefix: 'pfbulk')
        target = UserKeys.invalidation(9400)
        target[:keys].each { |key| cache.write(key, { x: 1 }) }
        def cache.write_many(*, **) = raise('no multi-write today')

        assert_equal [target], BulkInvalidation.call([target], cache: cache)

        assert(target[:keys].none? { |key| cache.read(key) })
        assert_equal [9400], @reported.pluck(:user_id)
      end

      test 'every stamp is written before any key is removed, and the users are confirmed' do
        cache = MemoryCache.new(prefix: 'pfbulk')
        targets = Array.new(3) { |i| UserKeys.invalidation(9000 + i, tenant_id: 7) }
        targets.flat_map { |target| target[:keys] }.each { |key| cache.write(key, { x: 1 }) }
        calls = recording(cache, :write_many, :expunge_many)

        assert_empty BulkInvalidation.call(targets, cache: cache)

        assert_equal %i[write_many expunge_many], calls.map(&:first)
        assert_equal targets.map { |target| target[:stamp_key] }, calls.first.last.keys
        assert(targets.all? { |target| cache.read(target[:stamp_key]).is_a?(String) })
        assert(targets.flat_map { |target| target[:keys] }.none? { |key| cache.read(key) })
      end

      test 'a slice the store never confirms is tried three times, then each user is reported and owed' do
        store = FailingStore.new
        store.down!
        targets = Array.new(2) { |i| UserKeys.invalidation(9100 + i) }

        failed = assert_nothing_raised { BulkInvalidation.call(targets, cache: RailsCache.new(store: store)) }

        assert_equal targets, failed
        assert_equal 3, store.operations.count([:write, targets.first[:stamp_key]])
        assert_equal(targets.map { |target| [target[:user_id], target[:keys], 3] },
                     @reported.map { |failure| failure.values_at(:user_id, :keys, :attempts) })
        assert(targets.all? { |target| Invalidation.backlog.include?(target[:stamp_key]) })
        assert Invalidation.store_failing?
      end

      test 'only the users the store did not confirm are tried again' do
        store = FailingStore.new
        flaky = UserKeys.invalidation(9200)
        fine = UserKeys.invalidation(9201)
        lost = 0
        store.fail_when = ->(operation, key) { operation == :write && key == flaky[:stamp_key] && (lost += 1) == 1 }

        assert_empty BulkInvalidation.call([flaky, fine], cache: RailsCache.new(store: store))

        assert_equal 2, store.operations.count([:write, flaky[:stamp_key]])
        assert_equal 1, store.operations.count([:write, fine[:stamp_key]])
        assert_empty @reported
      end

      # As Invalidation#remove(confirm: false): a key whose user's stamp was
      # refused is deleted once, not deleted and then confirmed with a write.
      test 'with the stamps refused the keys are only deleted, not paid for twice' do
        store = FailingStore.new
        store.down!
        targets = Array.new(2) { |i| UserKeys.invalidation(9150 + i, tenant_id: 3) }

        BulkInvalidation.call(targets, cache: RailsCache.new(store: store))

        keys = targets.sum { |target| target[:keys].size }
        assert_equal({ write: 2 * 3, delete: keys * 3 }, store.operations.map(&:first).tally, '3 attempts')
      end

      test 'a refused stamp still deletes the keys of a multi-write store in one call' do
        cache = RailsCache.new(store: redis_store(url: 'redis://127.0.0.1:1/15'))
        calls = store_calls { BulkInvalidation.call([UserKeys.invalidation(9160), UserKeys.invalidation(9161)], cache: cache) }

        assert_equal 2 * 3, calls.size, '1 stamp write + 1 removal per attempt'
      end

      test 'right after a failure a slice gets a single attempt' do
        Invalidation.store_failed!
        store = FailingStore.new
        store.down!
        target = UserKeys.invalidation(9300)

        BulkInvalidation.call([target], cache: RailsCache.new(store: store))

        assert_equal 1, store.operations.count([:write, target[:stamp_key]])
        assert_equal [1], @reported.pluck(:attempts)
      end

      # --- HolderInvalidation ---------------------------------------------------------

      test 'the holders are invalidated by id only where nothing else would happen for a user' do
        assert HolderInvalidation.by_id?(User)

        overriding(:invalidate_permissions) { assert_not HolderInvalidation.by_id?(User) }
        overriding(:invalidate_permissions, on: SubclassedUser) { assert_not HolderInvalidation.by_id?(User), 'an STI subclass' }
        overriding(:permission_cache_key) { assert_not HolderInvalidation.by_id?(User) }
        overriding(:pf_invalidation_stamp_key) { assert_not HolderInvalidation.by_id?(User), 'the stamp key (CQ-N1: pf_)' }
        overriding(:invalidation_stamp_key) { assert HolderInvalidation.by_id?(User), 'a host method the gem no longer calls' }
        assert_not HolderInvalidation.by_id?(Customer), 'a model without the concern'

        subscriber = ActiveSupport::Notifications.subscribe('permissions.invalidated.permission_forge') { |*| nil }
        PermissionForge::Audit.reset!
        assert_not HolderInvalidation.by_id?(User), 'a listener gets each user with its event'
        ActiveSupport::Notifications.unsubscribe(subscriber)
        PermissionForge::Audit.reset!
        assert HolderInvalidation.by_id?(User)

        PermissionForge.configuration.snapshot_transactions = true
        ActiveRecord::Base.transaction do
          assert_not HolderInvalidation.by_id?(User), 'settled per user after the commit'
        end
      end

      test 'by id the same stamp and keys are written and removed as by invalidate_permissions' do
        user = create_user
        tenant_id = DEFAULT_TEST_ACCOUNT.id
        cache = PermissionForge.cache

        one = recording(cache, :write, :expunge) { user.invalidate_permissions(tenant_id: tenant_id) }
        many = recording(cache, :write_many, :expunge_many) do
          HolderInvalidation.call(user_ids: [user.id], tenant_id: tenant_id)
        end

        assert_equal arguments(one, :write), arguments(many, :write_many).flat_map(&:keys)
        assert_equal arguments(one, :expunge), arguments(many, :expunge_many).flatten
      end

      # Q9 changed what this pins (was: both paths read the base entries'
      # index entries first and remove the variants they name with them).
      # Both paths remove the same keys, the base keys of both namespaces;
      # neither reads anything nor removes a variant, which no read can reach
      # once the base entry that carries its token is gone.
      test 'by id the same keys as by invalidate_permissions; neither reads, neither removes a variant' do
        user = create_user
        tenant_id = DEFAULT_TEST_ACCOUNT.id
        mfa_holder(user)
        cache = PermissionForge.cache

        warm_variant(user)
        one = recording(cache, :read, :expunge) { user.invalidate_permissions(tenant_id: tenant_id) }
        warm_variant(user)
        many = recording(cache, :read, :expunge_many) { HolderInvalidation.call(user_ids: [user.id], tenant_id: tenant_id) }

        assert_empty arguments(one, :read) + arguments(many, :read), 'nothing is read'
        removed = arguments(one, :expunge)
        assert_equal removed, arguments(many, :expunge_many).flatten, 'the same keys, this namespace, then the previous one'
        assert_empty removed.grep(/_c_/), 'no variant key'
      ensure
        PermissionForge.configuration.request_context_resolver = -> { {} }
      end

      # Q9: the variants go where personal data must go now — erasure, and
      # cache:clear by enumeration — through one definition
      # (UserKeys.variant_removals, VariantRemoval): the index entry and
      # every slot of a base key. The clear reads the index entries and
      # removes the base keys that have one; erasure (review F-1) reads
      # nothing and removes every base key's.
      test 'erasure and the clear remove the variants by the same keys: the index entry and every slot of the base key' do
        user = create_user
        mfa_holder(user)
        cache = PermissionForge.cache
        slots = lambda do |base|
          [PermissionForge::ConditionalSets.index_key(base), *PermissionForge::ConditionalSets.variant_keys(base)]
        end
        expected = slots.call(user.permission_cache_key)

        warm_variant(user)
        cleared = recording(cache, :expunge_many) { VariantRemoval.call(user_ids: [user.id], tenant_id: DEFAULT_TEST_ACCOUNT.id) }
        assert_empty stored_variant_keys, 'a variant with the profile outlived the clear'
        warm_variant(user)
        erased = recording(cache, :expunge_many) { PermissionForge::Services::DataSubjectErasure.call(user: User.find(user.id)) }
        assert_empty stored_variant_keys, 'a variant with the profile outlived the erasure'

        # (the erasure's assignments invalidate their user by id too: the base keys)
        assert_equal expected.sort, arguments(cleared, :expunge_many).flatten.grep(/_c_/).sort, 'the clear: the base key with an index'
        every = UserKeys.base_keys(user.id).first.flat_map(&slots)
        assert_equal every.sort, arguments(erased, :expunge_many).flatten.grep(/_c_/).sort, 'erasure: every base key, nothing read'
      ensure
        PermissionForge.configuration.request_context_resolver = -> { {} }
      end

      test 'a read of the index entries that raises counts as found: every slot is removed, not none' do
        cache = PermissionForge.cache
        cache.define_singleton_method(:read_many) { |_keys| raise IOError, 'the store is down' }

        removal = UserKeys.variant_removals([9500]).sole

        expected = UserKeys.base_keys(9500).first.flat_map do |key|
          [PermissionForge::ConditionalSets.index_key(key), *PermissionForge::ConditionalSets.variant_keys(key)]
        end
        assert_equal expected, removal[:keys]
        assert_equal UserKeys.stamp_key(9500), removal[:stamp_key]
      ensure
        cache.singleton_class.send(:remove_method, :read_many)
      end

      test 'a user who never had a variant stored costs the variant removal one read and no removal' do
        user = create_user
        cache = PermissionForge.cache
        User.find(user.id).permissions_hash

        calls = recording(cache, :read, :expunge_many, :write_many) { VariantRemoval.call(user_ids: [user.id], tenant_id: nil) }

        assert_equal [], arguments(calls, :expunge_many) + arguments(calls, :write_many)
        assert_equal(UserKeys.base_keys(user.id).first.map { |key| PermissionForge::ConditionalSets.index_key(key) },
                     arguments(calls, :read))
      end

      test 'an edit in a set with more holders than a slice invalidates every one by id, in slices' do
        set = create_permission_set
        holders = holders_of(set, count: (HolderInvalidation::SLICE * 2) + 100)
        field = create_resource_field(resource: create_resource(permission_set: set, name: 'Customer'), name: 'name')
        keys = holders.map { |id| "tenant_#{DEFAULT_TEST_ACCOUNT.id}_user_#{id}" }
        keys.each { |key| PermissionForge.cache.write(key, { stale: true }) }
        statements = nil
        single = counting_single_invalidations do
          calls = recording(PermissionForge.cache, :write_many, :expunge_many) do
            statements = capturing_sql { field.update!(edit_access: true) }
          end

          assert_equal [HolderInvalidation::SLICE, HolderInvalidation::SLICE, 100], arguments(calls, :write_many).map(&:size)
          assert_equal 3, arguments(calls, :expunge_many).size
        end

        assert_equal 0, single, 'no holder is invalidated on its own'
        assert(keys.none? { |key| PermissionForge.cache.read(key) })
        assert(holders.all? { |id| PermissionForge.cache.read("user_#{id}_invalidation").is_a?(String) })
        assert_empty statements.grep(/FROM ["`]users["`]/), 'no holder is loaded'
        assert_empty statements.grep(/SELECT ["`]permission_set_users["`]\.\*/), 'no assignment is loaded'
      end

      test 'a slice whose invalidation raises is owed and reported, and the next slice still goes through' do
        ids = Array.new(HolderInvalidation::SLICE + 1) { |i| 9500 + i }
        original = BulkInvalidation.method(:call)
        raised = false
        replace_singleton_method(BulkInvalidation, :call) do |targets, **options|
          next original.call(targets, **options) if raised

          raised = true
          raise 'the slice broke'
        end

        failed = HolderInvalidation.call(user_ids: ids, tenant_id: nil)

        assert_equal ids.first(HolderInvalidation::SLICE), failed
        assert_equal HolderInvalidation::SLICE, @reported.size
        # owed: the next confirmed slice makes up the first Backlog::PER_PASS of them at once
        assert_kind_of String, PermissionForge.cache.read(UserKeys.stamp_key(ids.first))
        assert Invalidation.backlog.include?(UserKeys.stamp_key(ids[HolderInvalidation::SLICE - 1]))
        assert_kind_of String, PermissionForge.cache.read(UserKeys.stamp_key(ids.last)), 'the next slice was invalidated'
      ensure
        replace_singleton_method(BulkInvalidation, :call, original)
      end

      test 'with a listener for permissions.invalidated each holder is invalidated as a user, with its event' do
        set = create_permission_set
        holders = holders_of(set, count: 3)
        field = create_resource_field(resource: create_resource(permission_set: set, name: 'Customer'), name: 'name')
        events = []
        subscriber = ActiveSupport::Notifications.subscribe('permissions.invalidated.permission_forge') do |*, payload|
          events << payload[:subject_user_id]
        end
        PermissionForge::Audit.reset!

        field.update!(edit_access: true)

        assert_equal holders.map(&:to_s).sort, events.map(&:to_s).sort
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
        PermissionForge::Audit.reset!
      end

      private

      def redis_store(url: REDIS_URL)
        require 'redis'
        if url == REDIS_URL
          begin
            Redis.new(url: url).ping
          rescue StandardError => e
            skip "no Redis at #{url}: #{e.class}"
          end
        end
        ActiveSupport::Cache::RedisCacheStore.new(url: url, pool: false, connect_timeout: 0.2, reconnect_attempts: 0)
      rescue LoadError
        skip 'the redis gem is not in this bundle'
      end

      def store_calls
        calls = []
        subscriber = ActiveSupport::Notifications.subscribe(/\Acache_\w+\.active_support\z/) { |name, *| calls << name }
        yield
        calls
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # [method, first argument] of each call of the named methods of
      # `cache` made inside the block (or from now on, without one: the
      # teardown replaces the store).
      def recording(cache, *names)
        calls = []
        names.each do |name|
          original = cache.method(name)
          cache.define_singleton_method(name) do |first, *rest, **options, &block|
            calls << [name, first]
            original.call(first, *rest, **options, &block)
          end
        end
        return calls unless block_given?

        begin
          yield
          calls
        ensure
          names.each { |name| cache.singleton_class.send(:remove_method, name) }
        end
      end

      # The first arguments of the recorded calls of one method.
      def arguments(calls, name)
        calls.filter_map { |called, first| first if called == name }
      end

      # The single-user Invalidations made inside the block.
      def counting_single_invalidations
        count = 0
        original = Invalidation.method(:call)
        replace_singleton_method(Invalidation, :call) do |*args, **options|
          count += 1
          original.call(*args, **options)
        end
        yield
        count
      ensure
        replace_singleton_method(Invalidation, :call, original)
      end

      def overriding(name, on: User)
        on.define_method(name) { |*args, **options| super(*args, **options) }
        yield
      ensure
        on.send(:remove_method, name)
      end

      # A base entry with the user's conditional sets and the variant of the
      # context, both cached (a fresh instance, read in the context).
      def warm_variant(user)
        User.find(user.id).permissions_hash
      end

      # Makes `user` hold an MFA-gated set, the context pass it.
      def mfa_holder(user)
        set = create_permission_set(name: 'MFA', requires_session_flag: 'mfa_verified')
        create_permission_set_user(user: user, permission_set: set)
        create_resource(permission_set: set, name: 'Customer', read_access: true)
        PermissionForge.configuration.request_context_resolver = -> { { session_flags: ['mfa_verified'] } }
      end

      # The variant and index keys that hold an entry.
      def stored_variant_keys
        PermissionForge.cache.instance_variable_get(:@store).keys.grep(/_c_/).select { |key| PermissionForge.cache.read(key.delete_prefix('pf:')) }
      end

      # `count` users holding `set`, written in bulk (a test fixture).
      def holders_of(set, count:)
        now = Time.current
        tag = SecureRandom.hex(3)
        User.insert_all!(Array.new(count) do |i|
          { uuid: SecureRandom.uuid, name: "Holder #{tag} #{i}", email: "h#{tag}#{i}@example.com", created_at: now, updated_at: now }
        end)
        ids = User.where('name LIKE ?', "Holder #{tag} %").order(:id).pluck(:id)
        PermissionForge::PermissionSetUser.insert_all!(ids.map do |id|
          { uuid: SecureRandom.uuid, user_id: id, permission_set_id: set.id, account_id: DEFAULT_TEST_ACCOUNT.id,
            created_at: now, updated_at: now }
        end)
        ids
      end

      def capturing_sql(&)
        statements = []
        callback = ->(*, payload) { statements << payload[:sql] unless payload[:name] == 'SCHEMA' }
        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
        statements
      end
    end
  end
end
