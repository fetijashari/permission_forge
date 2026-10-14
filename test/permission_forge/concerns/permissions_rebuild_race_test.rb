# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Concerns
    # A read-through rebuild that races an invalidation: it reads the
    # permission rows, a commit invalidates the user, and only then does the
    # rebuild store what it read. Without a check that pre-commit hash would
    # stay cached until cache_ttl. The tests run the commit at exactly that
    # point — between "rows read" and "hash stored" — through the cache store.
    class PermissionsRebuildRaceTest < ActiveSupport::TestCase
      # Seconds a threaded test waits for the other thread before it fails.
      WAIT = 10

      # A file store with ActiveSupport's LocalCache strategy, as the Redis,
      # Memcached and Solid Cache stores have it.
      class LocalCopyStore < ActiveSupport::Cache::FileStore
        prepend ActiveSupport::Cache::Strategy::LocalCache
      end

      setup do
        @user = create_user
        @set = create_permission_set
        @assignment = create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @name = create_resource_field(resource: @resource, name: 'name')
        @email = create_resource_field(resource: @resource, name: 'email')
        @key = @user.permission_cache_key
        @stamp_key = "user_#{@user.id}_invalidation"
        PermissionForge.cache.delete(@key)
      end

      # --- the race ---------------------------------------------------------------

      test 'a multi-record commit between the rows read and the cache write leaves no pre-commit hash' do
        commit = lambda do
          ActiveRecord::Base.transaction do
            @name.update!(edit_access: true)
            @email.update!(edit_access: true)
            @resource.update!(create_access: true)
          end
        end
        returned = nil

        writes = interrupting_hash_writes(commit) { returned = reader.permissions_hash }

        assert_equal 2, writes, 'the hash was built once more'
        [cached, returned].each do |hash|
          assert hash.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
          assert hash.dig(:permissions, :resources, :Customer, :permissions, :create_access)
        end
      end

      test 'a single-record commit between the rows read and the cache write leaves no pre-commit hash' do
        returned = nil

        writes = interrupting_hash_writes(-> { @name.update!(edit_access: true) }) { returned = reader.permissions_hash }

        assert_equal 2, writes
        assert cached.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
        assert returned.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
      end

      test 'a revocation between the rows read and the cache write does not stay granted' do
        person = reader

        writes = interrupting_hash_writes(-> { @assignment.destroy! }) { person.permissions_hash }

        assert_equal 2, writes
        assert_nil cached.dig(:permissions, :resources, :Customer)
        assert_not person.can_read?(:Customer)
        assert_not reader.can_read?(:Customer)
      end

      test 'regenerate_permissions called directly makes the same check' do
        writes = interrupting_hash_writes(-> { @name.update!(edit_access: true) }) { reader.regenerate_permissions }

        assert_equal 2, writes
        assert cached.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
      end

      test 'the check works through an ActiveSupport cache store' do
        PermissionForge.configuration.cache_backend = ActiveSupport::Cache::MemoryStore.new
        PermissionForge.configuration.reset_cache_store!

        writes = interrupting_hash_writes(-> { @name.update!(edit_access: true) }) { reader.permissions_hash }

        assert_equal 2, writes
        assert_kind_of String, PermissionForge.cache.read(@stamp_key)
        assert cached.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
      ensure
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      # The finest interleaving: the pre-commit hash is stored right after the
      # invalidation deleted the key, and the rebuild finishes before the
      # invalidation does anything else. Only a stamp written BEFORE the delete
      # is there for the rebuild to see.
      test 'a rebuild that stores its hash right after the delete still notices the invalidation' do
        rebuild = nil
        holding_first_hash_write_until_the_key_is_deleted(-> { rebuild }) do |rows_read|
          rebuild = Thread.new do
            ActsAsTenant.test_tenant = DEFAULT_TEST_ACCOUNT # per thread
            reader.permissions_hash
          end
          assert rows_read.pop(timeout: WAIT), 'the rebuild never reached its cache write'
          @name.update_columns(edit_access: true)
          @user.invalidate_permissions
          assert rebuild.join(WAIT), 'the rebuild never finished'
        end

        assert cached.nil? || cached.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access),
               'a pre-commit hash survived the invalidation'
      end

      # --- the caches of a request ----------------------------------------------------

      # Inside a request ActiveRecord caches query results. The other process's
      # commit does not clear this request's query cache, so the test changes
      # the row behind it, through the database driver.
      test 'the repeated build reads the rows again, not the query cache of the request' do
        commit_elsewhere = lambda do
          change_behind_the_query_cache(@name, edit_access: true)
          @user.invalidate_permissions
        end
        returned = nil

        ActiveRecord::Base.cache do
          writes = interrupting_hash_writes(commit_elsewhere) { returned = reader.permissions_hash }

          assert_equal 2, writes
        end

        assert cached.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
        assert returned.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
      end

      test 'a second rebuild in the same request reads the rows again' do
        ActiveRecord::Base.cache do
          person = reader
          assert_not person.permissions_hash.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)

          change_behind_the_query_cache(@name, edit_access: true)
          @user.invalidate_permissions

          assert person.permissions_hash.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
        end
        assert cached.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
      end

      # A cache store with a per-request local copy remembers the first read
      # of the stamp. The invalidation runs on another thread, as another
      # process would: it does not touch this request's copy.
      test 'the stamp is read past the local copy the cache store keeps for a request' do
        Dir.mktmpdir do |dir|
          store = LocalCopyStore.new(dir)
          PermissionForge.configuration.cache_backend = store
          PermissionForge.configuration.reset_cache_store!
          commit_elsewhere = lambda do
            @name.update_columns(edit_access: true)
            Thread.new { User.find(@user.id).invalidate_permissions(tenant_id: DEFAULT_TEST_ACCOUNT.id) }.join
          end

          store.with_local_cache do
            writes = interrupting_hash_writes(commit_elsewhere) { reader.permissions_hash }

            assert_equal 2, writes
          end

          assert cached.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
        end
      ensure
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      # --- the repeat itself ------------------------------------------------------------

      test 'the overtaken hash is gone before the repeat stores anything' do
        seen_during_repeat = :not_looked
        first = -> { @name.update!(edit_access: true) }
        second = -> { seen_during_repeat = cached }

        interrupting_hash_writes(first, second) { reader.permissions_hash }

        assert_nil seen_during_repeat, 'other requests could read the pre-commit hash while the repeat ran'
        assert cached.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
      end

      test 'a repeat that raises leaves nothing behind' do
        builder = PermissionForge::Services::PermissionHashBuilder
        original = builder.method(:call)
        builds = 0
        replace_singleton_method(builder, :call) do |**options|
          builds += 1
          raise ActiveRecord::QueryCanceled, 'statement timeout' if builds == 2

          original.call(**options)
        end

        assert_raises(ActiveRecord::QueryCanceled) do
          interrupting_hash_writes(-> { @name.update!(edit_access: true) }) { reader.permissions_hash }
        end

        assert_nil cached
        assert reader.permissions_hash.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
      ensure
        replace_singleton_method(builder, :call, original)
      end

      test 'a stamp that cannot be read back after storing means the entry is not kept' do
        cache = PermissionForge.cache
        read_fresh = cache.method(:read_fresh)
        reads = 0
        replace_singleton_method(cache, :read_fresh) do |key|
          reads += 1
          raise 'cache is down' if reads == 2

          read_fresh.call(key)
        end

        # a store call that raises is no answer: the request gets its hash
        hash = assert_nothing_raised { reader.permissions_hash }

        assert hash.dig(:permissions, :resources, :Customer)
        assert_nil cached
      ensure
        cache.singleton_class.send(:remove_method, :read_fresh)
      end

      # --- racing twice -------------------------------------------------------------

      # Another rebuild that raced an invalidation has its stale hash in the
      # store for the instant between its write and its own check. A request
      # that has just verified its hash must not swap it for that one.
      test 'the request keeps the hash it built and verified, not what another writer left in the store meanwhile' do
        person = reader
        stale = { permissions: { resources: {} } }
        stamp_reads = 0
        another_writer = lambda do |previous, key|
          stamp = previous.call(key)
          PermissionForge.cache.write(@key, stale) if key == @stamp_key && (stamp_reads += 1) == 2
          stamp
        end

        hash = wrapping_cache(:read_fresh, another_writer) { person.permissions_hash }

        assert_equal 2, stamp_reads, 'before the build, and after the hash was stored'
        assert hash.dig(:permissions, :resources, :Customer, :permissions, :read_access)
        assert_same hash, person.permissions_hash
      end

      test 'regenerate_permissions leaves the hash it built on the instance: the next read asks the store for nothing' do
        person = reader

        person.regenerate_permissions

        assert_empty(recording_cache_operations { assert person.can_read?(:Customer) })
        assert_equal cached, person.permissions_hash
      end

      test 'a rebuild overtaken twice caches nothing and keeps what it built to itself' do
        person = reader
        first = -> { @name.update!(edit_access: true) }
        second = -> { @email.update!(edit_access: true) }
        returned = nil

        writes = interrupting_hash_writes(first, second) { returned = person.permissions_hash }

        assert_equal 2, writes, 'no third attempt'
        assert_nil cached, 'a hash built across an invalidation is not left in the cache'
        fields = returned.dig(:permissions, :resources, :Customer, :fields)
        assert fields.dig(:name, :edit_access), 'the request that asked gets what its last build read'
        assert_not fields.dig(:email, :edit_access), 'which is from before the second commit'
        assert_same returned, person.permissions_hash

        fresh = reader.permissions_hash.dig(:permissions, :resources, :Customer, :fields)
        assert fresh.dig(:email, :edit_access), 'the next read rebuilds'
        assert_not_nil cached
      end

      test 'what an overtaken rebuild keeps is retired by the next invalidation' do
        person = reader
        first = -> { @name.update!(edit_access: true) }
        second = -> { @email.update!(edit_access: true) }
        interrupting_hash_writes(first, second) { person.permissions_hash }

        @resource.update!(create_access: true)

        assert person.can_create?(:Customer)
        assert person.field_permissions(:Customer, :email)[:edit_access]
      end

      # A host app overrides regenerate_permissions, calls super and derives
      # its own cache entry from permissions_hash.
      test 'a host override that reads permissions_hash after super never sees an empty hash' do
        derived = []
        User.define_method(:regenerate_permissions) do
          super()
          derived << permissions_hash.dig(:permissions, :resources)&.keys
        end
        first = -> { @name.update!(edit_access: true) }
        second = -> { @email.update!(edit_access: true) }

        interrupting_hash_writes(first, second) { reader.permissions_hash }

        assert_equal [[:Customer]], derived
      ensure
        User.send(:remove_method, :regenerate_permissions)
      end

      # The host's own entry has the same race on its own write: it compares
      # the stamp from before super with the stamp after writing the entry.
      test 'a host override can keep its derived entry from outliving an invalidation' do
        derived = {}
        User.define_method(:regenerate_permissions) do
          stamp = permission_invalidation_stamp
          super()
          derived[id] = permissions_hash.dig(:permissions, :resources, :Customer, :fields, :email, :edit_access)
          derived.delete(id) unless permission_invalidation_stamp == stamp
        end
        first = -> { @name.update!(edit_access: true) }
        second = -> { @email.update!(edit_access: true) }

        interrupting_hash_writes(first, second) { reader.permissions_hash }
        assert_empty derived, 'derived from a hash built before the second commit'

        reader.permissions_hash
        assert_equal({ @user.id => true }, derived)
      ensure
        User.send(:remove_method, :regenerate_permissions)
      end

      # --- one instance, several threads ---------------------------------------------

      # One user instance read on two threads at once, both missing the cache
      # (here a host override of regenerate_permissions that does something
      # slow before super holds the first one back). Each build hands its hash
      # back on its own thread: the second one finishing first takes nothing
      # from the first.
      test 'two threads rebuilding one user instance at once each get the hash, never {}' do
        person = reader
        tenant = ActsAsTenant.test_tenant
        held = Queue.new
        release = Queue.new
        person.define_singleton_method(:regenerate_permissions) do
          if Thread.current[:pf_test_held]
            held << true
            release.pop(timeout: WAIT)
          end
          super()
        end
        reading = lambda do |hold|
          Thread.new do
            Thread.current[:pf_test_held] = hold
            ActsAsTenant.test_tenant = tenant
            person.permissions_hash
          end
        end

        first = reading.call(true)
        held.pop(timeout: WAIT)
        second = reading.call(false)
        second_hash = second.value
        release << true
        first_hash = first.value

        [first_hash, second_hash, person.permissions_hash].each do |hash|
          assert hash.dig(:permissions, :resources, :Customer, :permissions, :read_access)
        end
        assert person.can_read?(:Customer)
      end

      # The build asks for the permissions of the user it builds for (a
      # masked getter read by the profile builder) and is answered {}. That
      # answer is for the build only: another thread reading the same
      # instance while the build goes on is never served it.
      test 'another thread never gets the {} a build was answered when it asked for itself' do
        person = reader
        held = Queue.new
        release = Queue.new
        profile_builder = PermissionForge.configuration.profile_builder
        PermissionForge.configuration.profile_builder = lambda do |user|
          if Thread.current[:pf_test_held]
            Thread.current[:pf_test_held] = false
            user.permissions_hash
            held << true
            release.pop(timeout: WAIT)
          end
          profile_builder.call(user)
        end
        tenant = ActsAsTenant.test_tenant
        building = Thread.new do
          Thread.current[:pf_test_held] = true
          ActsAsTenant.test_tenant = tenant
          person.permissions_hash
        end
        assert held.pop(timeout: WAIT)

        meanwhile = person.permissions_hash
        release << true

        [meanwhile, building.value, person.permissions_hash].each do |hash|
          assert hash.dig(:permissions, :resources, :Customer, :permissions, :read_access)
        end
      ensure
        PermissionForge.configuration.profile_builder = profile_builder
      end

      # A host override whose super runs on another thread (or fiber) does not
      # hand its hash back on this one; super memoized it on the instance.
      test 'a host override that runs super on another thread still gets the hash' do
        person = reader
        tenant = ActsAsTenant.test_tenant
        person.define_singleton_method(:regenerate_permissions) do
          Thread.new do
            ActsAsTenant.test_tenant = tenant
            super()
          end.value
        end

        assert person.permissions_hash.dig(:permissions, :resources, :Customer, :permissions, :read_access)
        assert person.can_read?(:Customer)
      end

      # An override that returns without building the hash for this cache
      # key — it skips super, or runs it where the tenant is another (a fiber
      # that does not carry it, or another tenant set on this very thread) —
      # leaves nothing to answer with. {} would deny every check and switch
      # row-level rules off, on every call, and another tenant's hash would
      # be memoized under this tenant's key, so it raises instead, naming the
      # key.
      test 'a host override that builds no hash for the key raises instead of answering {}' do
        other = Account.create!(name: 'Other Tenant')
        skipping = reader
        skipping.define_singleton_method(:regenerate_permissions) { nil }
        in_a_fiber = reader
        in_a_fiber.define_singleton_method(:regenerate_permissions) { Fiber.new { super() }.resume }
        in_another_tenant = reader
        in_another_tenant.define_singleton_method(:regenerate_permissions) do
          previous = ActsAsTenant.test_tenant
          ActsAsTenant.test_tenant = other
          super()
        ensure
          ActsAsTenant.test_tenant = previous
        end
        without_tenant = reader
        without_tenant.define_singleton_method(:regenerate_permissions) { ActsAsTenant.without_tenant { super() } }

        [skipping, in_a_fiber, in_another_tenant, without_tenant].each do |person|
          error = assert_raises(PermissionForge::ConfigurationError) { person.permissions_hash }
          assert_includes error.message, @key
          assert_includes error.message, 'super'
          assert_raises(PermissionForge::ConfigurationError) { person.can_read?(:Customer) }
        end
      end

      # --- what it costs ------------------------------------------------------------

      test 'a plain rebuild reads the stamp twice and stores once' do
        person = reader

        operations = recording_cache_operations { person.permissions_hash }

        assert_equal [[:read, @key], [:read, @stamp_key], [:write, @key], [:read, @stamp_key]], operations
      end

      test 'a cache hit costs one read and a memo hit none' do
        reader.permissions_hash
        person = reader

        assert_equal([[:read, @key]], recording_cache_operations { person.permissions_hash })
        assert_empty(recording_cache_operations { 3.times { person.can_read?(:Customer) } })
      end

      test 'a rebuild that repeats deletes the overtaken entry and reads the stamp twice more' do
        person = reader
        operations = nil
        invalidation = invalidation_operations

        interrupting_hash_writes(-> { @user.invalidate_permissions }) do
          operations = recording_cache_operations { person.permissions_hash }
        end

        # the invalidation runs while the first hash is on its way into the store
        assert_equal [[:read, @key], [:read, @stamp_key], [:write, @key], *invalidation, [:read, @stamp_key],
                      [:delete, @key], [:read, @stamp_key], [:write, @key], [:read, @stamp_key]],
                     operations
      end

      test 'a plain invalidation stamps once, before it deletes' do
        operations = recording_cache_operations { reader.invalidate_permissions }

        assert_equal invalidation_operations, operations
      end

      test 'an invalidation with a tenant id still stamps once' do
        operations = recording_cache_operations { reader.invalidate_permissions(tenant_id: 987) }

        assert_equal invalidation_operations(tenant_id: 987), operations
      end

      test 'the keys are deleted even when writing the stamp raises' do
        reader.permissions_hash
        cache = PermissionForge.cache
        write = cache.method(:write)
        replace_singleton_method(cache, :write) do |key, value, **options|
          raise 'cache is down' if key.end_with?('_invalidation')

          write.call(key, value, **options)
        end
        person = reader
        person.permissions_hash
        version = PermissionForge.permissions_cache_version

        reported = []
        PermissionForge.configuration.on_cache_failure = ->(**failure) { reported << failure }

        assert_nothing_raised { person.invalidate_permissions }

        assert_nil cached
        assert_operator PermissionForge.permissions_cache_version, :>, version
        assert_equal([:invalidate], reported.map { |failure| failure[:operation] })
        assert_equal 'cache is down', reported.first[:error].message
      ensure
        cache.singleton_class.send(:remove_method, :write)
      end

      # --- the stamp ----------------------------------------------------------------

      # For host apps: an override of regenerate_permissions that derives its
      # own cache entry after super compares the stamp around its own write.
      test 'the stamp can be read by a host app and changes with every invalidation' do
        @user.invalidate_permissions
        first = @user.permission_invalidation_stamp
        @user.invalidate_permissions(tenant_id: 5)

        assert_kind_of String, first
        assert_not_equal first, @user.permission_invalidation_stamp
      end

      test 'every invalidation leaves a new stamp, kept as long as a hash may live' do
        ttls = []
        cache = PermissionForge.cache
        original = cache.method(:write)
        replace_singleton_method(cache, :write) do |key, value, **options|
          ttls << options[:ttl] if key.end_with?('_invalidation')
          original.call(key, value, **options)
        end

        @user.invalidate_permissions
        first = PermissionForge.cache.read(@stamp_key)
        PermissionForge.configuration.cache_ttl = nil
        @user.invalidate_permissions

        assert_not_equal first, PermissionForge.cache.read(@stamp_key)
        assert_equal [3600, nil], ttls
      ensure
        cache.singleton_class.send(:remove_method, :write)
      end

      test 'an invalidation of somebody else does not make a rebuild repeat' do
        other = create_user(name: 'Other')

        writes = interrupting_hash_writes(-> { other.invalidate_permissions }) { reader.permissions_hash }

        assert_equal 1, writes
        assert_not_nil cached
      end

      # No caching means building every time — not an empty hash, which would
      # deny every check and switch the record rules off.
      test 'a cache that stores nothing gives every request the hash that was built' do
        PermissionForge.configure { |config| config.cache_backend = :null }
        reported = []
        PermissionForge.configuration.on_cache_failure = ->(**failure) { reported << failure }
        person = reader

        assert_nothing_raised do
          person.invalidate_permissions
          person.regenerate_permissions
        end

        assert person.can_read?(:Customer)
        assert reader.permissions_hash.dig(:permissions, :resources, :Customer)
        assert_empty reported, 'storing nothing is not a failure'
      ensure
        PermissionForge.configure { |config| config.cache_backend = :memory }
      end

      private

      # A user as a request loads it: no memo yet.
      def reader
        User.find(@user.id)
      end

      def cached
        PermissionForge.cache.read(@key)
      end

      # Runs the n-th interruption after the rows were read for the n-th time
      # and right before that hash is stored. Returns how many times the hash
      # was stored.
      def interrupting_hash_writes(*interruptions, &)
        key = @key
        writes = 0
        interrupt = lambda do |write, name, value, **options|
          if name == key
            writes += 1
            interruptions[writes - 1]&.call
          end
          write.call(name, value, **options)
        end
        wrapping_cache(:write, interrupt, &)
        writes
      end

      # The first store of the hash waits until the key has been deleted; the
      # delete then waits for the rebuild (the thread the lambda returns) to
      # finish before the invalidation continues. Yields a queue that gets an
      # item once the rebuild has read its rows.
      def holding_first_hash_write_until_the_key_is_deleted(rebuild)
        rows_read = Queue.new
        deleted = Queue.new
        wrapping_cache(:write, hold_first_hash_write(rows_read, deleted)) do
          wrapping_cache(:delete, finish_rebuild_after_the_delete(deleted, rebuild)) { yield rows_read }
        end
      end

      def hold_first_hash_write(rows_read, deleted)
        key = @key
        held = false
        lambda do |write, name, value, **options|
          if name == key && !held
            held = true
            rows_read << true
            deleted.pop(timeout: WAIT)
          end
          write.call(name, value, **options)
        end
      end

      def finish_rebuild_after_the_delete(deleted, rebuild)
        key = @key
        lambda do |delete, name|
          delete.call(name).tap do
            # the invalidation's delete, not the one a repeating rebuild makes itself
            next unless name == key && rebuild.call != Thread.current && rebuild.call.alive?

            deleted << true
            rebuild.call.join(WAIT)
          end
        end
      end

      def recording_cache_operations(&block)
        operations = []
        record = lambda do |name|
          lambda do |original, key, *args, **options|
            operations << [name, key]
            original.call(key, *args, **options)
          end
        end
        nested = %i[read write delete].reduce(block) do |inner, name|
          -> { wrapping_cache(name, record.call(name), &inner) }
        end
        nested.call
        operations
      end

      # Puts `replacement` in front of a method of the cache for the block. It
      # is called with the method it replaces and the arguments. Nests: what
      # was there before is put back.
      def wrapping_cache(name, replacement)
        cache = PermissionForge.cache
        previous = cache.method(name)
        own = cache.singleton_class.method_defined?(name, false)
        replace_singleton_method(cache, name) { |*args, **options| replacement.call(previous, *args, **options) }
        yield
      ensure
        own ? replace_singleton_method(cache, name, previous) : cache.singleton_class.send(:remove_method, name)
      end

      # The store operations of one invalidation: the stamp is written, then
      # every key is removed — this namespace, then the previous one
      # (PermissionCacheAccessor#invalidate_permissions). Nothing is read
      # (Q9: the variants are left to their TTL, unreachable).
      def invalidation_operations(tenant_id: nil)
        current, previous = PermissionForge::Cache::UserKeys.base_keys(@user.id, tenant_id: tenant_id)
        [[:write, @stamp_key], *(current + previous).map { |key| [:delete, key] }]
      end

      # Another process committed: the row changes, and nothing tells the
      # query cache of this connection.
      def change_behind_the_query_cache(record, attributes)
        model = record.class
        assignments = attributes.map do |column, value|
          "#{model.connection.quote_column_name(column)} = #{model.connection.quote(value)}"
        end
        sql = "UPDATE #{model.quoted_table_name} SET #{assignments.join(', ')} WHERE id = #{Integer(record.id)}"
        driver = model.connection.raw_connection
        driver.public_send(%i[exec execute query].find { |name| driver.respond_to?(name) }, sql)
      end
    end
  end
end
