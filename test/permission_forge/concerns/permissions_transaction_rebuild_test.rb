# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Concerns
    # Inside a database transaction that reads from a snapshot the cache is
    # not touched: a hash built there may come from a snapshot older than the
    # latest invalidation (REPEATABLE READ, SERIALIZABLE). The request uses
    # what it built, and does not read the store again, for as long as that
    # transaction is open. An explicit regenerate_permissions (or
    # invalidate_permissions) there says that something changed, so the user
    # is invalidated once the transaction has committed.
    #
    # Whether a transaction reads from a snapshot is
    # config.snapshot_transactions; these tests switch it on, so they say the
    # same on every database. (What happens with it off is in
    # permissions_transaction_passthrough_test.rb.)
    #
    # The transaction that wraps each test is not joinable and does not
    # count: outside `ActiveRecord::Base.transaction` blocks these tests
    # cache like production code outside a transaction, and a block commits —
    # and runs its commit callbacks — the way a top-level transaction does.
    class PermissionsTransactionRebuildTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @set = create_permission_set
        @assignment = create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @name = create_resource_field(resource: @resource, name: 'name')
        @key = @user.permission_cache_key
        @stamp_key = "user_#{@user.id}_invalidation"
        # the tenant the hash is built under: the one a settlement names at the commit
        @tenant_id = PermissionForge.ambient_tenant_id
        PermissionForge.configuration.snapshot_transactions = true
        PermissionForge.cache.delete(@key)
      end

      # --- nothing is shared from inside a transaction ------------------------------

      test 'outside a transaction a rebuild is cached (the transaction of the test does not count)' do
        assert_nil PermissionForge::OpenTransaction.current
        assert reader.can_read?(:Customer)

        assert_not_nil cached
      end

      test 'inside a transaction a rebuild is used by the request and not cached' do
        person = reader

        ActiveRecord::Base.transaction do
          hash = person.permissions_hash

          assert hash.dig(:permissions, :resources, :Customer, :permissions, :read_access)
          assert_same hash, person.permissions_hash, 'memoized for the request'
          assert_nil cached
        end

        assert_nil cached
      end

      test 'the next read outside a transaction rebuilds and caches' do
        ActiveRecord::Base.transaction { reader.permissions_hash }
        assert_nil cached

        assert reader.can_read?(:Customer)

        assert_not_nil cached
      end

      test 'a savepoint inside a transaction is a transaction too' do
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true) { assert reader.can_read?(:Customer) }
        end

        assert_nil cached
      end

      test 'a transaction that is not joinable counts inside an ordinary one' do
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true, joinable: false) { reader.permissions_hash }
        end

        assert_nil cached
      end

      # What test-prof's before_all and DatabaseCleaner put around a test: a
      # second transaction that is not joinable. Rails runs nothing through
      # such a transaction that would tell it apart from the one of the test.
      test 'a second transaction that is not joinable does not count either' do
        connection = ActiveRecord::Base.connection
        connection.begin_transaction(joinable: false)

        builds = counting_builds { 3.times { assert reader.can_read?(:Customer) } }

        assert_equal 1, builds
        assert_not_nil cached
      ensure
        connection.rollback_transaction
      end

      # --- what it costs --------------------------------------------------------------

      test 'a cache hit inside a transaction costs one read and builds nothing' do
        reader.permissions_hash
        person = reader
        operations = nil

        builds = counting_builds do
          ActiveRecord::Base.transaction do
            operations = recording_cache_operations { person.permissions_hash }
          end
        end

        assert_equal [[:read, @key]], operations
        assert_equal 0, builds
        assert_not_nil cached, 'a hit leaves the entry alone'
      end

      test 'a rebuild inside a transaction reads the cache once and makes no other store call, at commit either' do
        person = reader

        operations = recording_cache_operations do
          ActiveRecord::Base.transaction { person.permissions_hash }
        end

        assert_equal [[:read, @key]], operations
      end

      test 'regenerate_permissions inside a transaction makes no store call until the commit' do
        reader.permissions_hash
        person = reader
        inside = nil

        after = recording_cache_operations do
          ActiveRecord::Base.transaction do
            inside = recording_cache_operations { person.regenerate_permissions }
            assert_not_nil cached, 'the entry holds committed rows: it stays until the commit'
          end
        end

        assert_empty inside
        assert_equal [[:read, @key], *invalidation_operations], after,
                     'the read is the test looking at the entry; then the invalidation at the commit'
        assert_nil cached
      end

      # --- regenerate_permissions settles at commit --------------------------------------

      # The reviewer's X6: a change without callbacks, a rebuild, and another
      # request that caches the rows as they still are before the commit.
      test 'a revocation without callbacks followed by regenerate_permissions leaves nothing stale after the commit' do
        reader.permissions_hash
        stamp = PermissionForge.cache.read(@stamp_key)
        person = reader

        ActiveRecord::Base.transaction do
          PermissionForge::PermissionSetUser.where(user_id: @user.id).delete_all
          person.regenerate_permissions
          assert_not person.can_read?(:Customer), 'the transaction sees its own change'
          cache_what_another_request_read_before_the_commit
        end

        assert_nil cached
        assert_not_equal stamp, PermissionForge.cache.read(@stamp_key), 'a rebuild that straddled the commit is caught by the stamp'
        assert_not reader.can_read?(:Customer)
        assert_not person.can_read?(:Customer)
      end

      test 'regenerate_permissions inside a transaction invalidates once per user, however often and on whichever instance' do
        calls = recording_invalidations do |made|
          ActiveRecord::Base.transaction do
            3.times { reader.regenerate_permissions }
            person = reader
            2.times { person.regenerate_permissions }
            assert_empty made, 'nothing before the commit'
          end
        end

        assert_equal [[@user.id, @tenant_id]], calls
      end

      test 'a transaction that rolls back settles nothing' do
        reader.permissions_hash
        before = cached

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            reader.regenerate_permissions
            raise ActiveRecord::Rollback
          end
        end

        assert_empty calls
        assert_equal before, cached
      end

      test 'a savepoint that commits settles when the outer transaction commits, not before' do
        calls = recording_invalidations do |made|
          ActiveRecord::Base.transaction do
            ActiveRecord::Base.transaction(requires_new: true) { reader.regenerate_permissions }
            assert_empty made
          end
        end

        assert_equal [[@user.id, @tenant_id]], calls
      end

      test 'a savepoint that rolls back drops what was asked for inside it, and only that' do
        other = create_user(name: 'Other')

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            User.find(other.id).regenerate_permissions
            ActiveRecord::Base.transaction(requires_new: true) do
              reader.regenerate_permissions
              raise ActiveRecord::Rollback
            end
          end
        end

        assert_equal [[other.id, @tenant_id]], calls
      end

      test 'a rebuild asked for again after its savepoint rolled back is settled' do
        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            person = reader
            ActiveRecord::Base.transaction(requires_new: true) do
              person.regenerate_permissions
              raise ActiveRecord::Rollback
            end
            person.regenerate_permissions
          end
        end

        assert_equal [[@user.id, @tenant_id]], calls
      end

      test 'the settlement survives a build that raises' do
        person = reader
        builder = PermissionForge::Services::PermissionHashBuilder
        original = builder.method(:call)
        replace_singleton_method(builder, :call) { |**| raise 'the build is broken' }

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            assert_raises(RuntimeError) { person.regenerate_permissions }
          end
        end

        assert_equal [[@user.id, @tenant_id]], calls
      ensure
        replace_singleton_method(builder, :call, original)
      end

      test 'a host invalidate_permissions that raises at the commit is reported and does not stop the others' do
        other = create_user(name: 'Other')
        reported = []
        PermissionForge.configuration.on_cache_failure = ->(**failure) { reported << failure }
        broken = @user.id
        made = []
        User.define_method(:invalidate_permissions) do |tenant_id: nil|
          raise 'host override bug' if id == broken

          made << id
          super(tenant_id: tenant_id)
        end

        assert_nothing_raised do
          ActiveRecord::Base.transaction do
            reader.regenerate_permissions
            User.find(other.id).regenerate_permissions
          end
        end

        assert_equal [other.id], made
        assert_equal([[:invalidate, @user.id]], reported.map { |failure| failure.values_at(:operation, :user_id) })
      ensure
        User.send(:remove_method, :invalidate_permissions)
      end

      # --- invalidate_permissions inside a transaction ------------------------------------

      test 'invalidate_permissions inside a transaction invalidates at once and again after the commit' do
        reader.permissions_hash
        person = reader

        calls = recording_invalidations do |made|
          ActiveRecord::Base.transaction do
            PermissionForge::PermissionSetUser.where(user_id: @user.id).delete_all
            person.invalidate_permissions
            assert_equal 1, made.size
            assert_nil cached
            cache_what_another_request_read_before_the_commit
          end
        end

        assert_equal 2, calls.size
        assert_nil cached
        assert_not reader.can_read?(:Customer)
      end

      test 'invalidate_permissions outside a transaction invalidates once' do
        calls = recording_invalidations { reader.invalidate_permissions }

        assert_equal 1, calls.size
      end

      # --- the hash the request keeps ---------------------------------------------------

      # The reviewer's X1 and X1b: the same user object after the ROLLBACK.
      test 'a grant that was rolled back is not kept by the object that rebuilt inside the transaction' do
        other = create_user(name: 'Other')
        { regenerate: :regenerate_permissions, miss: :permissions_hash }.each do |how, call|
          person = User.find(other.id)
          PermissionForge.cache.delete(person.permission_cache_key)

          ActiveRecord::Base.transaction do
            create_permission_set_user(user: person, permission_set: @set)
            person.public_send(call)
            assert person.can_read?(:Customer), "#{how}: the transaction sees its own grant"
            raise ActiveRecord::Rollback
          end

          assert_not person.can_read?(:Customer), "#{how}: the same object after the rollback"
          assert_not User.find(other.id).can_read?(:Customer), "#{how}: a newly loaded user"
        end
      end

      test 'after the commit the object rebuilds from the database and the hash is cached normally' do
        person = reader
        inside = nil
        ActiveRecord::Base.transaction do
          @name.update_columns(edit_access: true)
          inside = person.permissions_hash
        end
        assert_nil cached

        after = person.permissions_hash

        assert_not_same inside, after
        assert after.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
        assert_equal after, cached
        assert_same after, person.permissions_hash, 'memoized again, now without a transaction to wait for'
      end

      test 'a hash built inside a savepoint is dropped when that savepoint rolls back' do
        person = reader

        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true) do
            @name.update_columns(edit_access: true)
            assert person.field_permissions(:Customer, :name)[:edit_access]
            raise ActiveRecord::Rollback
          end

          assert_not person.field_permissions(:Customer, :name)[:edit_access], 'still inside the outer transaction'
        end
      end

      # A hash built inside a transaction holds rows only that transaction
      # sees. A thread on another connection (a user instance shared across
      # threads) is not served it. The threads of a test share one
      # connection, so another connection is stood in for.
      test 'a hash built inside a transaction is not served on another connection' do
        person = reader

        ActiveRecord::Base.transaction do
          hash = person.permissions_hash

          assert_nil(on_another_connection { person.send(:pf_memoized_permissions, @key) })
          assert_same hash, person.permissions_hash
        end
      end

      test 'a user that holds a hash built inside a transaction can still be marshalled, and the copy does not keep the hash' do
        person = reader

        ActiveRecord::Base.transaction do
          hash = person.permissions_hash
          memo = person.instance_variable_get(:@_pf_permissions_memo)
          assert_equal [@key, PermissionForge.permissions_cache_version, PermissionForge::OpenTransaction, hash],
                       [memo.key, memo.version, memo.transaction.class, memo.permissions]

          copy = Marshal.load(Marshal.dump(person))
          # what ActiveRecord's 6.1 marshalling format carries over: every
          # instance variable — the memo whole, under the key and version
          # that are current, and with the transaction it is tied to
          copy.instance_variable_set(:@_pf_permissions_memo, Marshal.load(Marshal.dump(memo)))

          assert_equal hash, copy.instance_variable_get(:@_pf_permissions_memo).permissions
          assert_nil copy.send(:pf_memoized_permissions, @key), 'built in a transaction the copy is not in'
          assert_same hash, person.permissions_hash
        end
      end

      # --- the instance does not go back to the store while its transaction is open -------

      # The reviewer's finding 2 (V1–V6): every rebuild and invalidation in the
      # process bumps the version that retires the memos. Retired inside the
      # transaction it was built in, a hash is built again — the store still
      # holds the entry from before the transaction.
      test 'a hash retired by somebody else inside the transaction is rebuilt, never read from the store' do
        other = create_user(name: 'Other')
        retiring = {
          'another user regenerates in the same transaction' => -> { User.find(other.id).regenerate_permissions },
          'another user is invalidated in the same transaction' => -> { User.find(other.id).invalidate_permissions },
          'another thread rebuilds or invalidates (a version bump)' => -> { PermissionForge.bump_permissions_cache_version! }
        }

        retiring.each do |what, bump|
          create_permission_set_user(user: @user, permission_set: @set) unless PermissionForge::PermissionSetUser.exists?(user_id: @user.id)
          reader.permissions_hash
          person = reader
          reads = nil

          ActiveRecord::Base.transaction do
            PermissionForge::PermissionSetUser.where(user_id: @user.id).delete_all
            person.regenerate_permissions
            assert_not person.can_read?(:Customer), what
            bump.call
            reads = recording_cache_operations { assert_not person.can_read?(:Customer), "#{what}: still revoked inside the transaction" }
          end

          assert_empty(reads.select { |_, key| key == @key }, what)
        end
      end

      test 'each user regenerated in one transaction keeps what it built' do
        others = Array.new(2) { |i| create_user(name: "Other #{i}") }
        others.each { |user| create_permission_set_user(user: user, permission_set: @set) }
        people = [@user, *others].map { |user| User.find(user.id) }
        people.each { |person| assert person.can_read?(:Customer) }
        seen = nil

        builds = counting_builds do
          ActiveRecord::Base.transaction do
            PermissionForge::PermissionSetUser.where(permission_set_id: @set.id).delete_all
            people.each(&:regenerate_permissions)
            seen = Array.new(3) { people.map { |person| person.can_read?(:Customer) } }
          end
        end

        assert_equal [[false, false, false]] * 3, seen
        assert_equal 5, builds, 'three asked for, and two built again after the others retired them — not one per check'
      end

      # A rebuild that was withheld changed nothing anybody else could read,
      # so it retires nobody's memo: two objects that both miss inside a
      # transaction do not keep rebuilding in turns.
      test 'a read-through rebuild inside a transaction does not retire the memo of another instance' do
        other = create_user(name: 'Other')
        people = [reader, User.find(other.id)]

        builds = counting_builds do
          ActiveRecord::Base.transaction { 5.times { people.each(&:permissions_hash) } }
        end

        assert_equal 2, builds
      end

      test 'after invalidate_permissions inside a transaction the instance builds for itself, whatever the store holds meanwhile' do
        reader.permissions_hash
        person = reader

        ActiveRecord::Base.transaction do
          PermissionForge::PermissionSetUser.where(user_id: @user.id).delete_all
          person.invalidate_permissions
          cache_what_another_request_read_before_the_commit

          assert_not person.can_read?(:Customer)
        end
      end

      test 'reload inside the transaction drops the hash and builds it again from the transaction' do
        reader.permissions_hash
        person = reader

        ActiveRecord::Base.transaction do
          PermissionForge::PermissionSetUser.where(user_id: @user.id).delete_all
          person.regenerate_permissions
          person.reload

          assert_not person.can_read?(:Customer)
        end
      end

      test 'a savepoint that is released leaves the hash built inside it in place' do
        person = reader

        builds = counting_builds do
          ActiveRecord::Base.transaction do
            20.times { ActiveRecord::Base.transaction(requires_new: true) { assert person.can_read?(:Customer) } }
            assert person.can_read?(:Customer)
          end
        end

        assert_equal 1, builds
      end

      test 'after a savepoint rolled back the instance builds again inside the outer transaction, and does not read the store' do
        reader.permissions_hash
        person = reader

        ActiveRecord::Base.transaction do
          PermissionForge::PermissionSetUser.where(user_id: @user.id).delete_all
          person.regenerate_permissions
          ActiveRecord::Base.transaction(requires_new: true) do
            @name.update_columns(edit_access: true)
            person.regenerate_permissions
            raise ActiveRecord::Rollback
          end

          reads = recording_cache_operations { assert_not person.can_read?(:Customer), 'the revocation of the outer transaction stands' }
          assert_empty reads
        end
      end

      test 'once the transaction has ended the instance reads the store again' do
        person = reader
        ActiveRecord::Base.transaction { person.permissions_hash }
        reader.permissions_hash # somebody caches it

        assert_equal([[:read, @key]], recording_cache_operations { person.permissions_hash })
      end

      test 'a hash read from the cache inside a transaction is kept after it' do
        reader.permissions_hash
        person = reader
        hash = nil

        ActiveRecord::Base.transaction { hash = person.permissions_hash }

        assert_same hash, person.permissions_hash
      end

      # The transaction changes a permission record, reads permissions (which
      # sees the change) and rolls back. The cache must not keep the change.
      test 'a transaction that rolls back leaves nothing of its own changes in the cache' do
        person = reader

        ActiveRecord::Base.transaction do
          @name.update!(edit_access: true)
          assert person.field_permissions(:Customer, :name)[:edit_access], 'the transaction sees its own change'
          raise ActiveRecord::Rollback
        end

        assert_nil cached
        assert_not reader.field_permissions(:Customer, :name)[:edit_access]
        assert_not person.field_permissions(:Customer, :name)[:edit_access]
      end

      test 'a transaction that commits invalidates what was cached before it' do
        reader.permissions_hash

        ActiveRecord::Base.transaction do
          @name.update!(edit_access: true)
          reader.permissions_hash
        end

        assert reader.field_permissions(:Customer, :name)[:edit_access]
      end

      test 'a concurrent version bump does not cost the request its hash' do
        person = reader
        builder = PermissionForge::Services::PermissionHashBuilder
        original = builder.method(:call)
        replace_singleton_method(builder, :call) do |**options|
          PermissionForge.bump_permissions_cache_version! # another thread invalidates somebody
          original.call(**options)
        end

        ActiveRecord::Base.transaction do
          assert person.permissions_hash.dig(:permissions, :resources, :Customer)
        end
      ensure
        replace_singleton_method(builder, :call, original)
      end

      # A host app overrides regenerate_permissions, calls super and derives
      # its own cache entry from permissions_hash.
      test 'a host override that reads permissions_hash after super sees the hash inside a transaction' do
        derived = []
        User.define_method(:regenerate_permissions) do
          super()
          derived << permissions_hash.dig(:permissions, :resources)&.keys
        end

        ActiveRecord::Base.transaction { reader.permissions_hash }

        assert_equal [[:Customer]], derived
      ensure
        User.send(:remove_method, :regenerate_permissions)
      end

      # --- rails console --sandbox -------------------------------------------------------------

      # A sandbox console is one transaction that is not joinable — here the
      # one of the test stands in for it — and everything done in it is
      # rolled back when the console exits. The cache is not, so nothing is
      # stored from inside it, whatever config.snapshot_transactions says.
      test 'in a sandbox console a grant that is tried out is not cached' do
        PermissionForge.configuration.snapshot_transactions = false
        Rails.application.sandbox = true
        other = create_user(name: 'Other')
        key = other.permission_cache_key

        create_permission_set_user(user: other, permission_set: @set)

        assert User.find(other.id).can_read?(:Customer), 'the sandbox sees its own grant'
        assert_nil PermissionForge.cache.read(key)
        assert ControllerActions::ManagedIndex.managed_resource?('Customer')
        assert_nil PermissionForge.cache.read(ControllerActions::ManagedIndex.send(:cache_key)), 'nor is the managed-actions index'
      ensure
        Rails.application.sandbox = false
      end

      # --- the notice ----------------------------------------------------------------------

      test 'rebuilds that keep being withheld are logged once per process' do
        log = capturing_log do
          ((PermissionForge::Cache::WithheldNotice::AFTER * 2) + 1).times do
            ActiveRecord::Base.transaction { reader.permissions_hash }
          end
        end

        assert_equal 1, log.scan('ran inside a database transaction that reads from a snapshot').size
        assert_match(/\[PermissionForge\] The last 20 permission rebuilds/, log)
      end

      test 'a rebuild that is stored in between starts the count again' do
        log = capturing_log do
          3.times do
            (PermissionForge::Cache::WithheldNotice::AFTER - 1).times do
              ActiveRecord::Base.transaction { reader.permissions_hash }
            end
            PermissionForge.cache.delete(@key)
            reader.permissions_hash
            PermissionForge.cache.delete(@key)
          end
        end

        assert_no_match(/ran inside a database transaction/, log)
      end

      private

      # The calling thread works on a connection of its own.
      def on_another_connection
        pool = PermissionForge::PermissionSet.connection_pool
        elsewhere = Object.new
        pool.define_singleton_method(:with_connection) { |*, &block| block.call(elsewhere) }
        yield
      ensure
        pool.singleton_class.send(:remove_method, :with_connection)
      end

      def reader
        User.find(@user.id)
      end

      def cached
        PermissionForge.cache.read(@key)
      end

      # What another request leaves in the cache when it rebuilds from the
      # rows as they are before the commit: the user still holds the set.
      def cache_what_another_request_read_before_the_commit
        stale = { permissions: { resources: { Customer: { permissions: { read_access: true } } } } }
        PermissionForge.cache.write(@key, stale)
      end

      def counting_builds
        builder = PermissionForge::Services::PermissionHashBuilder
        original = builder.method(:call)
        builds = 0
        replace_singleton_method(builder, :call) do |**options|
          builds += 1
          original.call(**options)
        end
        yield
        builds
      ensure
        replace_singleton_method(builder, :call, original)
      end

      # The [operation, key] of every call to the cache inside the block.
      def recording_cache_operations(&)
        operations = []
        recording = ->(name) { ->(previous, key, *args, **options) { (operations << [name, key]) && previous.call(key, *args, **options) } }
        wrapping_cache(:read, recording[:read]) do
          wrapping_cache(:write, recording[:write]) { wrapping_cache(:delete, recording[:delete], &) }
        end
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

      # The [user id, tenant id] of every User#invalidate_permissions call made
      # inside the block. Yields the list so a test can look at it mid-way.
      def recording_invalidations
        calls = []
        User.define_method(:invalidate_permissions) do |tenant_id: nil|
          calls << [id, tenant_id]
          super(tenant_id: tenant_id)
        end
        yield calls
        calls
      ensure
        User.send(:remove_method, :invalidate_permissions)
      end

      def capturing_log
        log = StringIO.new
        logger = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(log)
        yield
        log.string
      ensure
        Rails.logger = logger
      end
    end

    # The same rule against real transactions: no transaction of a test around
    # them, so the stack is what production code sees. What a test creates
    # here is committed, and removed again in teardown.
    class PermissionsRealTransactionRebuildTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @user = create_user
        @set = create_permission_set
        @assignment = create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @outsider = create_user(name: 'Outsider')
        @key = @user.permission_cache_key
        PermissionForge.configuration.snapshot_transactions = true
        PermissionForge.cache.delete(@key)
      end

      teardown do
        users = [@user, @outsider].compact.map(&:id)
        PermissionForge::PermissionSetUser.unscoped.where(user_id: users).delete_all
        PermissionForge::Resource.unscoped.where(permission_set_id: @set&.id).delete_all
        PermissionForge::PermissionSet.unscoped.where(id: @set&.id).delete_all
        User.unscoped.where(id: users).delete_all
        # The audit events those committed writes left behind.
        PermissionForge::AuditEvent.unscoped.delete_all
      end

      test 'outside a transaction a rebuild is cached' do
        User.find(@user.id).permissions_hash

        assert_not_nil cached
      end

      test 'inside a transaction, a savepoint, or a non-joinable transaction nested in one, nothing is cached' do
        ActiveRecord::Base.transaction { User.find(@user.id).permissions_hash }
        assert_nil cached

        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true) { User.find(@user.id).permissions_hash }
        end
        assert_nil cached

        # the reviewer's finding 2: the innermost transaction is not joinable
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true, joinable: false) { User.find(@user.id).permissions_hash }
        end
        assert_nil cached
      end

      # The reviewer's X1c.
      test 'a grant rolled back around a non-joinable transaction does not reach the cache' do
        key = @outsider.permission_cache_key

        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
            person = User.find(@outsider.id)
            create_permission_set_user(user: person, permission_set: @set)
            person.regenerate_permissions
            assert person.can_read?(:Customer)
          end
          raise ActiveRecord::Rollback
        end

        assert_nil PermissionForge.cache.read(key)
        assert_not User.find(@outsider.id).can_read?(:Customer)
      end

      test 'regenerate_permissions inside a non-joinable transaction nested in an ordinary one settles after the COMMIT' do
        User.find(@user.id).permissions_hash
        depths = []
        User.define_method(:invalidate_permissions) do |tenant_id: nil|
          depths << self.class.connection.open_transactions
          super(tenant_id: tenant_id)
        end

        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true, joinable: false) { User.find(@user.id).regenerate_permissions }
          assert_empty depths
          assert_not_nil cached
        end

        assert_equal [0], depths
        assert_nil cached
      ensure
        User.send(:remove_method, :invalidate_permissions)
      end

      # Known limit: a single non-joinable transaction is what wraps a test,
      # and Rails gives nothing to tell the two apart.
      test 'a single transaction that is not joinable is not recognised' do
        ActiveRecord::Base.transaction(joinable: false) { User.find(@user.id).permissions_hash }

        assert_not_nil cached
      end

      private

      def cached
        PermissionForge.cache.read(@key)
      end
    end
  end
end
