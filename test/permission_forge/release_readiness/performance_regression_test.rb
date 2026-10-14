# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module ReleaseReadiness
    # The pre-release review of 2026-10-12, performance lane: the cost model where a host grows, as bounds on query
    # and store-operation counts (never timings). MAJOR-3 (boot without a
    # database) is proved by shipped_defaults_regression_test.rb and MAJOR-4
    # (the dead RedisCache backend) by claims_regression_test.rb. Each test
    # failed on v0.13.0.
    class PerformanceRegressionTest < ActiveSupport::TestCase
      # The table a query reads, however the adapter quotes it.
      FROM_TABLE = /FROM\s+["`]?(\w+)["`]?/i

      # A store that can take several entries in one round trip, as Redis
      # and Solid Cache can, counting what the gem asks of it. Passed through
      # the public config.cache_backend, like a host's own store.
      class CountingStore < ActiveSupport::Cache::MemoryStore
        attr_reader :calls

        def initialize(*)
          super
          @calls = Hash.new(0)
        end

        def write(name, value, options = nil)
          @calls[:write] += 1
          @calls[:stamp_writes] += 1 if name.to_s.end_with?('_invalidation')
          super
        end

        def delete(name, options = nil)
          @calls[:delete] += 1
          super
        end

        def write_multi_entries(entries, **options)
          @calls[:write_multi] += 1
          @calls[:stamp_writes] += entries.keys.count { |name| name.to_s.end_with?('_invalidation') }
          super
        end

        def round_trips = @calls[:write] + @calls[:delete] + @calls[:write_multi]
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      def counting_store
        store = CountingStore.new
        PermissionForge.configuration.cache_backend = store
        PermissionForge.configuration.reset_cache_store!
        store
      end

      def sql_of(&)
        queries = []
        callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached] }
        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
        queries
      end

      # A user holding `sets` granting sets of `resources` resources with
      # `fields` fields, `actions` actions and `rules` rules each.
      def holder_of(sets:, resources:, fields:, actions: 0, rules: 0)
        user = create_user
        sets.times do |s|
          set = create_permission_set(name: "Set #{s}")
          create_permission_set_user(user: user, permission_set: set)
          resources.times do |r|
            resource = create_resource(permission_set: set, name: "PfRrPerfRes#{r}", read_access: true, edit_access: true)
            fields.times { |f| create_resource_field(resource: resource, name: "field_#{f}") }
            actions.times { |a| create_resource_action(resource: resource, name: "action_#{a}", is_permitted: true) }
            rules.times { |i| create_permission_set_rule(permission_set: set, resource: resource, field_name: 'domain', field_value: "v#{i}") }
          end
        end
        user
      end

      # Rows for `count` users, none of them loaded: holders of `set`. (The
      # ids are read back: MySQL's insert_all returns none.)
      def holders_of(set, count)
        stamp = { account_id: DEFAULT_TEST_ACCOUNT.id, created_at: Time.current, updated_at: Time.current }
        domain = "holders-#{SecureRandom.hex(4)}.test"
        User.insert_all(Array.new(count) { |i| { uuid: SecureRandom.uuid, name: "Holder #{i}", email: "h#{i}@#{domain}", **stamp } }) # test setup
        ids = User.where('email LIKE ?', "%@#{domain}").order(:id).pluck(:id)
        PermissionForge::PermissionSetUser.insert_all( # test setup
          ids.map do |id|
            { uuid: SecureRandom.uuid, permission_set_id: set.id, user_id: id, **stamp }
          end
        )
        ids
      end

      # ---- MAJOR-1: a rebuild ran ~4 queries per resource ----------------------------

      # Every holder rebuilds read-through after any edit to one of their
      # sets; 10 sets x 20 resources cost 828 queries per holder.
      test 'PERF-M1 a permission-hash rebuild runs a fixed number of queries whatever the number of resources' do
        small = holder_of(sets: 1, resources: 1, fields: 2)
        large = holder_of(sets: 4, resources: 5, fields: 6, actions: 2, rules: 2)
        PermissionForge.cache.clear

        small_queries = sql_of { User.find(small.id).permissions_hash }
        large_queries = sql_of { User.find(large.id).permissions_hash }

        assert_operator large_queries.size, :<=, 10, large_queries.join("\n")
        assert_equal small_queries.size, large_queries.size, 'the count must not grow with the rows'
        %w[resources resource_fields resource_actions permission_set_rules].each do |table|
          assert_equal 1, large_queries.count { |sql| sql[FROM_TABLE, 1] == table }, "#{table} is read once"
        end
      end

      # ---- MAJOR-2: invalidating N holders was 3N-5N store round trips and 2N loaded rows ----

      # One field edit in a set with 1,200 holders, inside the admin's own
      # request: no holder may be loaded, and the store sees a few multi-key
      # calls per slice of 500, not three per holder.
      test 'PERF-M2 one edit to a set with many holders costs a bounded number of store round trips and loads no holder' do
        set = create_permission_set(name: 'Big')
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        field = create_resource_field(resource: resource, name: 'name')
        holder_ids = holders_of(set, 1200)
        slices = (1200 / 500.0).ceil
        store = counting_store
        User.find(holder_ids.first).permissions_hash
        store.calls.clear

        queries = sql_of { field.update!(mask_access: true) }

        assert_operator store.round_trips, :<=, (4 * slices) + 4, store.calls.inspect
        assert_equal 0, store.calls[:delete], 'keys are removed in bulk, not one delete per holder'
        assert_equal 0, queries.count { |sql| sql[FROM_TABLE, 1] == 'users' }, 'no holder is loaded'
        assert queries.none? { |sql| sql.length > 10_000 }, 'no IN-list of every holder id'
        assert_equal 1200, store.calls[:stamp_writes], 'every holder is still stamped'
        assert_not User.find(holder_ids.first).masked_field?(:Customer, :name) == false, 'the edit reached the holder'
      end

      # ---- MINOR-1: bulk assignment invalidated every user twice ---------------------

      test 'PERF-m1 a bulk assignment stamps each user once' do
        set = create_permission_set(name: 'Bulk')
        create_resource(permission_set: set, name: 'Customer', read_access: true)
        ids = Array.new(30) { create_user.id }
        store = counting_store

        result = PermissionForge::Services::BulkPermissionSetAssignment.call(permission_set: set, user_ids: ids, action: :assign)

        assert_equal 30, result[:assigned]
        assert_equal 30, store.calls[:stamp_writes], store.calls.inspect
        assert User.find(ids.last).can_read?(:Customer)
      end

      # ---- MINOR-2: the managed-actions request memo grew per cache-version bump ----

      test 'PERF-m2 the managed-actions request memo keeps one slot per key across many invalidations' do
        set = create_permission_set(name: 'Managed')
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        create_resource_action(resource: resource, name: 'export', is_permitted: true)
        user = create_user
        PermissionForge::ControllerActions::ManagedIndex::RequestMemo.reset

        50.times do
          user.invalidate_permissions # a job invalidating many users, with a guard decision between each
          PermissionForge::ControllerActions::ManagedIndex.managed_actions('Customer')
        end

        assert_equal 1, PermissionForge::ControllerActions::ManagedIndex::RequestMemo.indexes.size
      ensure
        PermissionForge::ControllerActions::ManagedIndex::RequestMemo.reset
      end

      # ---- MINOR-3: the GDPR boot scan instantiated every unmasked field ----------------

      test 'PERF-m3 the GDPR boot scan is one query over many unmasked fields that match nothing' do
        set = create_permission_set(name: 'Many fields')
        resource = create_resource(permission_set: set, name: 'PfRrPerfRes0', read_access: true)
        stamp = { account_id: DEFAULT_TEST_ACCOUNT.id, created_at: Time.current, updated_at: Time.current }
        PermissionForge::ResourceField.insert_all( # test setup
          Array.new(1100) do |i|
            { uuid: SecureRandom.uuid, resource_id: resource.id, name: "plain_#{i}", label: "Plain #{i}", read_access: true, **stamp }
          end
        )
        configuration = PermissionForge.configuration
        assert_not configuration.gdpr_defaults

        queries = sql_of { PermissionForge::BootChecks.warn_unmasked_gdpr_fields(configuration) }

        assert_operator queries.count { |sql| sql[FROM_TABLE, 1] == 'resource_fields' }, :<=, 1, queries.join("\n")
      end

      # ---- Pre-release review, NEW-MAJOR-1: every invalidation read every holder's full hash ----

      # The keys `PermissionForge.cache` is asked to read inside the block
      # (read_many reads key by key on MemoryCache).
      def keys_read
        cache = PermissionForge.cache
        read = []
        cache.define_singleton_method(:read) do |key|
          read << key
          super(key)
        end
        yield
        read
      ensure
        cache.singleton_class.send(:remove_method, :read)
      end

      def mfa_holder
        user = create_user
        set = create_permission_set(name: 'MFA', requires_session_flag: 'mfa_verified')
        create_permission_set_user(user: user, permission_set: set)
        create_resource(permission_set: set, name: 'Customer', read_access: true, delete_access: true)
        PermissionForge.configuration.request_context_resolver = -> { { session_flags: ['mfa_verified'] } }
        user
      end

      def stored_permission_keys(user)
        PermissionForge.cache.instance_variable_get(:@store).keys.grep(/user_#{user.id}(_c_|\z)/)
                       .select { |key| PermissionForge.cache.read(key.delete_prefix('pf:')) }
      end

      # The base entries (kilobytes each with real grants) were read only to
      # find the variant keys they name: 10,000 holders x 24 KB took 10 s on
      # Redis. Now the few-byte index entries are read, and only a user who
      # had a variant stored has one.
      test 'PERF-N1 invalidating holders reads no cached permission hash, only the index entries' do
        set = create_permission_set(name: 'Staff')
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        field = create_resource_field(resource: resource, name: 'name')
        holder_ids = holders_of(set, 3)
        holder_ids.each { |id| User.find(id).permissions_hash }
        base_keys = holder_ids.map { |id| PermissionForge::Cache::UserKeys.hash_key(id) }

        bulk = keys_read { field.update!(mask_access: true) }
        holder_ids.each { |id| User.find(id).permissions_hash }
        single = keys_read { User.find(holder_ids.first).invalidate_permissions }

        assert_empty (bulk + single) & base_keys, 'a cached hash was read by the invalidation'
        assert((bulk + single).all? { |key| key.end_with?('_c_index') }, (bulk + single).inspect)
        assert_nil PermissionForge.cache.read(base_keys.first), 'the entry is still removed'
      ensure
        PermissionForge.configuration.request_context_resolver = -> { {} }
      end

      # Q9 changed what this pins (was: "a cached variant is found through
      # its index entry and goes with the user, by id and one by one"): an
      # invalidation by id removes the base entry only, and the variant it
      # leaves is never served again; erasure removes it through the index.
      test 'PERF-N1 a cached variant is found through its index entry and goes on erasure; by id it is never served again' do
        user = mfa_holder
        User.find(user.id).permissions_hash
        assert_equal 3, stored_permission_keys(user).size, 'precondition: base, index entry and variant are cached'
        PermissionForge::Resource.where(name: 'Customer').find_each { |row| row.update_columns(delete_access: false) } # test setup

        PermissionForge::Cache::HolderInvalidation.call(user_ids: [user.id], tenant_id: DEFAULT_TEST_ACCOUNT.id)
        assert_nil PermissionForge.cache.read(PermissionForge::Cache::UserKeys.hash_key(user.id)), 'by id: the base entry goes'
        assert_equal 2, stored_permission_keys(user).size, 'by id: the index entry and the variant are left to their TTL'
        assert_not User.find(user.id).can_delete?(:Customer), 'the variant left behind was served'

        User.find(user.id).permissions_hash
        PermissionForge::Services::DataSubjectErasure.call(user: User.find(user.id))
        assert_empty stored_permission_keys(user), 'erasure: no variant with the profile survives'
      ensure
        PermissionForge.configuration.request_context_resolver = -> { {} }
      end

      test 'PERF-N1 a variant whose index entry the store refuses is not stored' do
        user = mfa_holder
        cache = PermissionForge.cache
        cache.define_singleton_method(:write) do |key, value, **options|
          key.end_with?('_c_index') ? false : super(key, value, **options)
        end

        assert User.find(user.id).can_delete?(:Customer), 'the request still gets the variant it built'
        assert_empty(stored_permission_keys(user).grep(/_c_/), 'a variant no index entry names was stored')
      ensure
        cache&.singleton_class&.send(:remove_method, :write)
        PermissionForge.configuration.request_context_resolver = -> { {} }
      end

      # Final-round verification (performance, B): the index entry was
      # written before the variant's rebuild read the stamp. An invalidation
      # in between removed the index, the rebuild then read the new stamp,
      # and the variant (with the profile) was stored with no index naming
      # it: it outlived every later invalidation and erasure for up to 300 s.
      # Q9: the invalidation that follows the race is an erasure (a normal
      # invalidation leaves the variants to their TTL); it must find them all.
      test 'PERF-N1 an invalidation as the variant build reads the stamp leaves no variant that no index names' do
        user = mfa_holder
        PermissionForge.configuration.request_context_resolver = -> { { session_flags: [] } }
        User.find(user.id).permissions_hash # the base entry, no variant
        PermissionForge.configuration.request_context_resolver = -> { { session_flags: ['mfa_verified'] } }
        cache = PermissionForge.cache
        stamp = PermissionForge::Cache::UserKeys.stamp_key(user.id)
        armed = true
        cache.define_singleton_method(:read_fresh) do |key|
          if armed && key == stamp
            armed = false
            User.find(user.id).invalidate_permissions # lands right as the variant build reads the stamp
          end
          super(key)
        end

        assert User.find(user.id).can_delete?(:Customer)
        cache.singleton_class.send(:remove_method, :read_fresh)
        PermissionForge::Services::DataSubjectErasure.call(user: User.find(user.id))

        assert_empty stored_permission_keys(user), 'a variant outlived the erasure'
      ensure
        cache.singleton_class.send(:remove_method, :read_fresh) if cache&.singleton_class&.method_defined?(:read_fresh, false)
        PermissionForge.configuration.request_context_resolver = -> { {} }
      end

      # ---- Q9 (code quality CQ-N4): 2^n - 1 variant keys per holder on every invalidation ------

      # Every invalidation read the holders' index entries and removed one key
      # per combination of their conditional sets: at 6 sets 67 keys per
      # holder, 7.4 s for 10,000 holders on Redis. A variant is unreachable
      # once the base entry that carries its token is gone, so only erasure
      # and cache:clear remove variants (conditional_sets_per_context_test,
      # permission_cache_clearer_test).
      test 'Q9 an invalidation reads nothing and removes the base keys only, at any number of conditional sets' do
        user = create_user
        flags = Array.new(PermissionForge::ConditionalSets::MAX_CACHED_SETS) { |i| "flag_#{i}" }
        flags.each do |flag|
          set = create_permission_set(name: flag, requires_session_flag: flag)
          create_permission_set_user(user: user, permission_set: set)
          create_resource(permission_set: set, name: 'Customer', read_access: true)
        end
        PermissionForge.configuration.request_context_resolver = -> { { session_flags: flags } }
        tenant_id = DEFAULT_TEST_ACCOUNT.id
        current, previous = PermissionForge::Cache::UserKeys.base_keys(user.id, tenant_id: tenant_id)

        User.find(user.id).permissions_hash
        assert_equal 3, stored_permission_keys(user).size, 'precondition: base, index entry and variant are cached'
        single = cache_calls { User.find(user.id).invalidate_permissions(tenant_id: tenant_id) }
        User.find(user.id).permissions_hash
        bulk = cache_calls { PermissionForge::Cache::HolderInvalidation.call(user_ids: [user.id], tenant_id: tenant_id) }

        { 'one by one' => single, 'by id' => bulk }.each do |path, calls|
          assert_empty calls[:read], "#{path}: nothing is read"
          assert_equal (current + previous).sort, calls[:expunge].sort, "#{path}: the base keys of both namespaces, no variant"
        end
      ensure
        PermissionForge.configuration.request_context_resolver = -> { {} }
      end

      # The keys the gem reads and removes during the block.
      def cache_calls
        cache = PermissionForge.cache
        calls = Hash.new { |hash, name| hash[name] = [] }
        %i[read expunge].each do |name|
          cache.define_singleton_method(name) do |key|
            calls[name] << key
            super(key)
          end
        end
        yield
        calls
      ensure
        %i[read expunge].each { |name| cache.singleton_class.send(:remove_method, name) }
      end
    end
  end
end
