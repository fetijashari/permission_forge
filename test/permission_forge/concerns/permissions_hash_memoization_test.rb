require 'test_helper'

module PermissionForge
  module Concerns
    # Instance-level memoization of permissions_hash: repeated reads must not
    # pay a cache-store round-trip per call, while every invalidation path
    # (own instance, other instance of the same user, reload, tenant switch)
    # must retire the memo. Store reads are counted through the supported
    # `cache_backend = <ActiveSupport store instance>` path.
    class PermissionsHashMemoizationTest < ActiveSupport::TestCase
      class CountingMemoryStore < ActiveSupport::Cache::MemoryStore
        attr_accessor :reads

        def initialize(*)
          super
          @reads = 0
        end

        def read(name, options = nil)
          @reads += 1
          super
        end
      end

      setup do
        @store = CountingMemoryStore.new
        PermissionForge.configuration.cache_backend = @store
        PermissionForge.configuration.reset_cache_store!

        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(permission_set: @permission_set, name: 'Customer', read_access: true)
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      test 'repeated permissions_hash calls read the store once and return the same object' do
        @user.regenerate_permissions
        first = @user.permissions_hash
        baseline = @store.reads

        5.times { assert_same first, @user.permissions_hash }

        assert_equal baseline, @store.reads
      end

      test 'permission checks reuse the memo instead of re-reading the store' do
        @user.regenerate_permissions
        @user.permissions_hash
        baseline = @store.reads

        10.times do
          assert @user.can_read?(:Customer)
          @user.field_permissions(:Customer, :name)
        end

        assert_equal baseline, @store.reads
      end

      test 'invalidate_permissions retires the memo on the same instance' do
        @user.regenerate_permissions
        before = @user.permissions_hash

        @user.invalidate_permissions
        after = @user.permissions_hash

        refute_same before, after
      end

      test 'an invalidation through a different instance of the same user retires the memo' do
        @user.regenerate_permissions
        reader = User.find(@user.id)
        memoized = reader.permissions_hash
        baseline = @store.reads

        User.find(@user.id).invalidate_permissions

        refute_same memoized, reader.permissions_hash
        assert_operator @store.reads, :>, baseline
      end

      test 'a memoized instance sees admin-side permission changes without reload' do
        reader = User.find(@user.id)
        assert reader.can_read?(:Customer)

        # after_commit → users' invalidate_permissions → memo version bump
        @resource.update!(read_access: false)

        assert_not reader.can_read?(:Customer)
      end

      test 'regenerate_permissions refreshes an existing memo' do
        reader = User.find(@user.id)
        before = reader.permissions_hash

        reader.regenerate_permissions
        after = reader.permissions_hash

        refute_same before, after
      end

      test 'reload drops the memo' do
        @user.regenerate_permissions
        memoized = @user.permissions_hash

        @user.reload

        refute_same memoized, @user.permissions_hash
      end

      test 'the memo does not leak across tenant cache keys' do
        @user.regenerate_permissions
        default_tenant_hash = @user.permissions_hash

        other_account = Account.create!(name: 'Other Tenant')
        ActsAsTenant.with_tenant(other_account) do
          refute_same default_tenant_hash, @user.permissions_hash
        end

        # Back under the default tenant the original grants are visible again.
        assert @user.can_read?(:Customer)
      end

      # --- one instance, several threads ---------------------------------------------

      # One user instance read on two threads. The first one is held back in
      # pf_memoize_permissions right before the line that stores the memo; the
      # other memoizes for its own key meanwhile. Whatever the instance keeps
      # afterwards is one memo or the other, whole: never the key of one with
      # the hash of the other.
      test 'two threads memoizing on one instance in different tenants never pair one key with the other hash' do
        other = Account.create!(name: 'Other Tenant')
        own_key = @user.permission_cache_key
        other_key = in_tenant(other) { @user.permission_cache_key }
        PermissionForge.cache.write(own_key, sentinel_hash('own'))
        PermissionForge.cache.write(other_key, sentinel_hash('other'))
        person = User.find(@user.id)

        held = holding_a_memoization(person) do
          assert_equal 'other', in_tenant(other) { tenant_of(person.permissions_hash) }
        end

        assert_equal 'own', tenant_of(held)
        assert_equal 'other', in_tenant(other) { tenant_of(person.permissions_hash) }, "the other tenant's key with this tenant's hash"
        assert_equal 'own', tenant_of(person.permissions_hash)
      end

      # The same tenant: the held thread read the store before an
      # invalidation, the other one after it. The hash from before must not
      # outlive the invalidation under the version that came after it.
      test 'a hash read before an invalidation is not kept under the version after it' do
        key = @user.permission_cache_key
        PermissionForge.cache.write(key, sentinel_hash('before'))
        person = User.find(@user.id)

        held = holding_a_memoization(person) do
          User.find(@user.id).invalidate_permissions
          PermissionForge.cache.write(key, sentinel_hash('after'))
          assert_equal 'after', tenant_of(person.permissions_hash)
        end

        assert_equal 'before', tenant_of(held)
        assert_equal 'after', tenant_of(person.permissions_hash), 'the hash from before the invalidation, still memoized'
      end

      # The held thread read the store, then an invalidation came, then it
      # memoized what it read: under the version from before its read, which
      # the invalidation retired.
      test 'a hash read from the store before an invalidation is memoized under the version from before the read' do
        key = @user.permission_cache_key
        PermissionForge.cache.write(key, sentinel_hash('before'))
        person = User.find(@user.id)

        held = holding_a_store_read(person) do
          User.find(@user.id).invalidate_permissions
          PermissionForge.cache.write(key, sentinel_hash('after'))
        end

        assert_equal 'before', tenant_of(held)
        assert_equal 'after', tenant_of(person.permissions_hash), 'the hash from before the invalidation, still memoized'
      end

      # A memo hit takes the memo once: the held thread checked this tenant's
      # memo, the other thread replaced it meanwhile, and what the held
      # thread returns is still the memo it checked.
      test 'a memo hit returns the memo it checked, also when another thread replaces it meanwhile' do
        other = Account.create!(name: 'Other Tenant')
        PermissionForge.cache.write(@user.permission_cache_key, sentinel_hash('own'))
        PermissionForge.cache.write(in_tenant(other) { @user.permission_cache_key }, sentinel_hash('other'))
        person = User.find(@user.id)
        person.permissions_hash

        held = holding_a_memo_read(person) do
          assert_equal 'other', in_tenant(other) { tenant_of(person.permissions_hash) }
        end

        assert_equal 'own', tenant_of(held)
      end

      private

      def sentinel_hash(tenant)
        { profile: { tenant: tenant }, preferences: {}, permissions: { resources: {} } }
      end

      def tenant_of(hash)
        hash.dig(:profile, :tenant)
      end

      # acts_as_tenant's with_tenant leaves the tenant it resolved behind in
      # its Current; the test tenant is set and put back instead.
      def in_tenant(tenant)
        previous = ActsAsTenant.test_tenant
        ActsAsTenant.test_tenant = tenant
        yield
      ensure
        ActsAsTenant.test_tenant = previous
      end

      # Runs the block while a thread reading person.permissions_hash (in
      # this thread's tenant) is held right before pf_memoize_permissions stores
      # the memo, then lets it finish. Returns what it read.
      def holding_a_memoization(person, &)
        memoize = PermissionsMemo.instance_method(:pf_memoize_permissions)
        line = memo_store_line(memoize)
        holding_a_reader(person, lambda do |hold, run|
          TracePoint.new(:line) { |point| hold.call if point.lineno == line }.enable(target: memoize, &run)
        end, &)
      end

      # The same, held right after its read of the cache store.
      def holding_a_store_read(person, &)
        cache = PermissionForge.cache
        holding_a_reader(person, lambda do |hold, run|
          cache.define_singleton_method(:read) { |*args| super(*args).tap { hold.call } }
          run.call
        ensure
          cache.singleton_class.send(:remove_method, :read)
        end, &)
      end

      # The same, held in pf_memoized_permissions after the line that reads the memo.
      def holding_a_memo_read(person, &)
        read = PermissionsMemo.instance_method(:pf_memoized_permissions)
        holding_a_reader(person, lambda do |hold, run|
          lines = 0
          TracePoint.new(:line) { (lines += 1) == 2 && hold.call }.enable(target: read, &run)
        end, &)
      end

      # Starts the reader inside `around` (called with the hold and the run),
      # waits until it is held, runs the block, and releases it.
      def holding_a_reader(person, around)
        held = Queue.new
        release = Queue.new
        around.call(holding(held, release), lambda do
          reader = held_reader(person)
          assert held.pop(timeout: 10), 'the reader was never held'
          yield
          release << true
          reader.value
        end)
      end

      # Holds the thread that asked for it, once.
      def holding(held, release)
        lambda do
          next unless Thread.current[:pf_test_hold]

          Thread.current[:pf_test_hold] = false
          held << true
          release.pop(timeout: 10)
        end
      end

      # A thread, in this thread's tenant, that asks to be held and reads.
      def held_reader(person)
        tenant = ActsAsTenant.test_tenant
        Thread.new do
          Thread.current[:pf_test_hold] = true
          ActsAsTenant.test_tenant = tenant
          person.permissions_hash
        end
      end

      # The line of pf_memoize_permissions that stores the memo.
      def memo_store_line(memoize)
        path, first = memoize.source_location
        lines = File.readlines(path)
        first + lines.drop(first).index { |line| line.match?(/@_pf_permissions_memo = (?!nil)/) } + 1
      end
    end
  end
end
