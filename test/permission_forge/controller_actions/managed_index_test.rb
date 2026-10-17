require 'test_helper'
require_relative '../tenancy/tenancy_test_helper'
require_relative '../cache/failing_store'

module PermissionForge
  module ControllerActions
    class ManagedIndexTest < ActiveSupport::TestCase
      include PermissionForge::Tenancy::TenancyTestHelper

      setup do
        @set = create_permission_set
        @resource = create_resource(permission_set: @set, name: 'Customer')
      end

      def cached_index
        PermissionForge.cache.read(ManagedIndex.send(:cache_key))
      end

      # Counts the reads of the index (not of its invalidation stamp, which a
      # build reads twice) made inside the block.
      def count_cache_reads
        cache = PermissionForge.cache
        reads = 0
        original = cache.method(:read)
        cache.define_singleton_method(:read) do |key|
          reads += 1 if key.end_with?(ManagedIndex::CACHE_KEY)
          original.call(key)
        end
        yield
        reads
      ensure
        cache.singleton_class.send(:remove_method, :read)
      end

      def with_failing_store
        store = PermissionForge::Cache::FailingStore.new
        PermissionForge.configuration.cache_backend = store
        PermissionForge.configuration.reset_cache_store!
        @reported = []
        PermissionForge.configuration.on_cache_failure = ->(**failure) { @reported << failure }
        yield store
      ensure
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      # Runs the n-th interruption right before the index is stored for the
      # n-th time. Returns how many times the index was stored.
      def interrupting_index_writes(*interruptions)
        cache = PermissionForge.cache
        key = ManagedIndex.send(:cache_key)
        writes = 0
        original = cache.method(:write)
        cache.define_singleton_method(:write) do |name, value, **options|
          if name == key
            writes += 1
            interruptions[writes - 1]&.call
          end
          original.call(name, value, **options)
        end
        yield
        writes
      ensure
        cache.singleton_class.send(:remove_method, :write)
      end

      def change_behind_the_query_cache(record, attributes)
        model = record.class
        assignments = attributes.map do |column, value|
          "#{model.connection.quote_column_name(column)} = #{model.connection.quote(value)}"
        end
        sql = "UPDATE #{model.quoted_table_name} SET #{assignments.join(', ')} WHERE id = #{Integer(record.id)}"
        driver = model.connection.raw_connection
        driver.public_send(%i[exec execute query].find { |name| driver.respond_to?(name) }, sql)
      end

      # A row written behind the callbacks (insert_all! runs none).
      def action_row(name)
        now = Time.current
        { uuid: SecureRandom.uuid, name: name, is_active: true, is_permitted: true,
          PermissionForge::ResourceAction.reflect_on_association(:resource).foreign_key => @resource.id,
          account_id: DEFAULT_TEST_ACCOUNT.id, created_at: now, updated_at: now }
      end

      test 'nothing is managed without rows' do
        assert_not ManagedIndex.managed_resource?('Supplier')
        assert_not ManagedIndex.managed_action?('Supplier', 'export')
        assert_not ManagedIndex.managed_action?('Customer', 'export')
      end

      test 'an active resource and action in an active set are managed' do
        create_resource_action(resource: @resource, name: 'export')

        assert ManagedIndex.managed_resource?('Customer')
        assert ManagedIndex.managed_resource?(:Customer)
        assert ManagedIndex.managed_action?('Customer', 'export')
        assert ManagedIndex.managed_action?(:Customer, :export)
        assert_not ManagedIndex.managed_action?('Customer', 'merge')
      end

      test 'managed_actions answers both questions in one lookup' do
        create_resource_action(resource: @resource, name: 'export')
        create_resource_action(resource: @resource, name: 'merge')

        assert_equal %w[export merge], ManagedIndex.managed_actions('Customer').sort
        assert_equal [], ManagedIndex.managed_actions('Customer').grep('sync')
        assert_nil ManagedIndex.managed_actions('Supplier')
      end

      test 'a managed resource with no actions answers an empty list, not nil' do
        assert_equal [], ManagedIndex.managed_actions(:Customer)
      end

      test 'a row that is not permitted still makes the action managed' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)

        assert ManagedIndex.managed_action?('Customer', 'export')
      end

      test 'rows in a muting set count as managed' do
        muting = create_permission_set(is_muting: true)
        muted = create_resource(permission_set: muting, name: 'Supplier', read_access: false)
        create_resource_action(resource: muted, name: 'sync', is_permitted: true)

        assert ManagedIndex.managed_resource?('Supplier')
        assert ManagedIndex.managed_action?('Supplier', 'sync')
      end

      test 'inactive actions, resources and sets are not managed' do
        create_resource_action(resource: @resource, name: 'export', is_active: false)
        assert_not ManagedIndex.managed_action?('Customer', 'export')

        inactive_resource = create_resource(permission_set: @set, name: 'Supplier', is_active: false)
        create_resource_action(resource: inactive_resource, name: 'sync')
        assert_not ManagedIndex.managed_resource?('Supplier')

        inactive_set = create_permission_set(is_active: false)
        # 'Order' is not a model, so no MaskedAttributes auto-apply is triggered.
        order = create_resource(permission_set: inactive_set, name: 'Order')
        create_resource_action(resource: order, name: 'close')
        assert_not ManagedIndex.managed_resource?('Order')
        assert_not ManagedIndex.managed_action?('Order', 'close')
      end

      test 'the index is cached and served from the cache' do
        create_resource_action(resource: @resource, name: 'export')
        assert ManagedIndex.managed_action?('Customer', 'export')
        assert_not_nil cached_index

        # A row changed behind the callbacks is not seen until invalidation.
        PermissionForge::ResourceAction.where(resource_id: @resource.id).update_all(is_active: false)
        assert ManagedIndex.managed_action?('Customer', 'export')

        ManagedIndex.invalidate!
        assert_not ManagedIndex.managed_action?('Customer', 'export')
      end

      test 'creating, destroying, renaming and switching rows drops the index' do
        assert_not ManagedIndex.managed_action?('Customer', 'export')

        action = create_resource_action(resource: @resource, name: 'export')
        assert ManagedIndex.managed_action?('Customer', 'export')

        action.update!(name: 'download')
        assert ManagedIndex.managed_action?('Customer', 'download')
        assert_not ManagedIndex.managed_action?('Customer', 'export')

        action.update!(is_active: false)
        assert_not ManagedIndex.managed_action?('Customer', 'download')

        action.update!(is_active: true)
        @set.update!(is_active: false)
        assert_not ManagedIndex.managed_resource?('Customer')

        @set.update!(is_active: true)
        assert ManagedIndex.managed_action?('Customer', 'download')

        @resource.destroy!
        assert_not ManagedIndex.managed_resource?('Customer')
      end

      # after_commit only sees the last save of a transaction, so the change
      # has to be noted when it happens.
      test 'a row created and saved again in one transaction still drops the index' do
        assert_not ManagedIndex.managed_action?('Customer', 'export')

        ActiveRecord::Base.transaction do
          action = create_resource_action(resource: @resource, name: 'export')
          action.update!(label: 'Export everything')
        end

        assert ManagedIndex.managed_action?('Customer', 'export')
      end

      test 'a row autosaved through its resource and saved again still drops the index' do
        assert_not ManagedIndex.managed_action?('Customer', 'export')

        ActiveRecord::Base.transaction do
          action = @resource.resource_actions.build(uuid: SecureRandom.uuid, name: 'export', is_active: true,
                                                    is_permitted: true)
          @resource.update!(create_access: true)
          action.save!
        end

        assert ManagedIndex.managed_action?('Customer', 'export')
      end

      test 'a row switched on and saved again in one transaction still drops the index' do
        action = create_resource_action(resource: @resource, name: 'export', is_active: false)
        assert_not ManagedIndex.managed_action?('Customer', 'export')

        ActiveRecord::Base.transaction do
          action.update!(is_active: true)
          action.update!(label: 'Export everything')
        end

        assert ManagedIndex.managed_action?('Customer', 'export')
      end

      # The note of a rolled-back save is not forgotten: the record's next
      # commit drops the index once more than needed. What the index says is
      # what counts.
      test 'a rolled-back change leaves the index correct, also after the next commit' do
        action = create_resource_action(resource: @resource, name: 'export')
        assert ManagedIndex.managed_action?('Customer', 'export')

        ActiveRecord::Base.transaction do
          action.update!(is_active: false)
          raise ActiveRecord::Rollback
        end
        assert ManagedIndex.managed_action?('Customer', 'export'), 'nothing was committed'

        action.reload.update!(is_permitted: true)

        assert ManagedIndex.managed_action?('Customer', 'export')
      end

      # A rollback to a savepoint undoes the later save only: the earlier one
      # is still committed, and so is what it changed.
      test 'a later save rolled back to a savepoint does not lose the note of an earlier save' do
        action = create_resource_action(resource: @resource, name: 'export')
        assert ManagedIndex.managed_action?('Customer', 'export')

        ActiveRecord::Base.transaction do
          action.update!(is_active: false)
          ActiveRecord::Base.transaction(requires_new: true) do
            action.update!(label: 'Rolled back')
            raise ActiveRecord::Rollback
          end
        end

        assert_not ManagedIndex.managed_action?('Customer', 'export')
      end

      # A touched record invalidates on its own, without the transaction's
      # batch: here only the note the record keeps for itself can drop the index.
      test 'the note of an earlier save survives a rolled-back savepoint on the record itself' do
        action = create_resource_action(resource: @resource, name: 'export')
        assert ManagedIndex.managed_action?('Customer', 'export')

        ActiveRecord::Base.transaction do
          action.update!(is_active: false)
          ActiveRecord::Base.transaction(requires_new: true) do
            action.update!(label: 'Rolled back')
            raise ActiveRecord::Rollback
          end
          action.touch
        end

        assert_not ManagedIndex.managed_action?('Customer', 'export')
      end

      # Rails runs the commit callbacks of one instance per row — here the one
      # that only changed the label.
      test 'two instances of one row: the change of the one whose after_commit does not run still drops the index' do
        action = create_resource_action(resource: @resource, name: 'export')
        twin = PermissionForge::ResourceAction.find(action.id)
        assert ManagedIndex.managed_action?('Customer', 'export')

        ActiveRecord::Base.transaction do
          action.update!(is_active: false)
          twin.update!(label: 'Export everything')
        end

        assert_not ManagedIndex.managed_action?('Customer', 'export')
      end

      # Nothing is raised out of after_commit (Rails would skip the callbacks
      # of the remaining records); the failure is reported instead.
      test 'the index is dropped even when invalidating the users raises' do
        create_permission_set_user(user: create_user, permission_set: @set)
        assert_not ManagedIndex.managed_action?('Customer', 'export')
        User.define_method(:invalidate_permissions) { |**| raise 'cache is down' }
        failures = []
        PermissionForge.configuration.on_cache_failure = ->(**failure) { failures << failure }

        assert_nothing_raised { create_resource_action(resource: @resource, name: 'export') }

        assert_nil cached_index
        assert ManagedIndex.managed_action?('Customer', 'export')
        assert_equal([:invalidate], failures.map { |failure| failure[:operation] })
        assert_equal 'cache is down', failures.first[:error].message
      ensure
        User.send(:remove_method, :invalidate_permissions)
      end

      test 'the users are invalidated even when dropping the index raises' do
        user = create_user
        create_permission_set_user(user: user, permission_set: @set)
        user.permissions_hash
        cache = PermissionForge.cache
        delete = cache.method(:delete)
        cache.define_singleton_method(:delete) do |key|
          raise 'cache is down' if key.end_with?(ManagedIndex::CACHE_KEY)

          delete.call(key)
        end

        failures = []
        PermissionForge.configuration.on_cache_failure = ->(**failure) { failures << failure }

        assert_nothing_raised { create_resource_action(resource: @resource, name: 'export') }

        assert_nil PermissionForge.cache.read(user.permission_cache_key)
        assert_equal([:invalidate], failures.map { |failure| failure[:operation] })
        assert_equal 'cache is down', failures.first[:error].message
        assert_includes failures.first[:keys], ManagedIndex.send(:cache_key)
      ensure
        cache.singleton_class.send(:remove_method, :delete)
      end

      # --- a store that does not confirm the removal --------------------------------

      test 'a delete the store does not confirm is made up for with an empty entry' do
        with_failing_store do |store|
          create_resource_action(resource: @resource, name: 'export')
          assert ManagedIndex.managed_action?('Customer', 'export')
          key = ManagedIndex.send(:cache_key)
          store.fail_when = ->(operation, name) { operation == :delete && name == key }

          assert ManagedIndex.invalidate!

          assert_nil cached_index, 'overwritten: a read of it is a miss'
          assert_empty @reported
        end
      end

      test 'a removal the store never confirms is reported with its keys, and not raised' do
        with_failing_store do |store|
          create_resource_action(resource: @resource, name: 'export')
          ManagedIndex.managed_action?('Customer', 'export')
          store.down!

          confirmed = nil
          assert_nothing_raised { confirmed = ManagedIndex.invalidate!(tenant_id: DEFAULT_TEST_ACCOUNT.id) }

          assert_equal false, confirmed
          assert_equal([:invalidate], @reported.map { |failure| failure[:operation] })
          assert_includes @reported.first[:keys], ManagedIndex.send(:cache_key)
          assert_includes @reported.first[:keys], ManagedIndex::CACHE_KEY
          assert_nil @reported.first[:user_id]
        end
      end

      test 'a commit that changes what is managed raises nothing while the store is down' do
        with_failing_store do |store|
          store.down!

          assert_nothing_raised { create_resource_action(resource: @resource, name: 'export') }

          assert_includes @reported.map { |failure| failure[:keys] }.flatten, ManagedIndex::CACHE_KEY
          assert ManagedIndex.managed_action?('Customer', 'export'), 'the request copy was dropped all the same'
        end
      end

      test 'every key is tried, also when the removal of one raises' do
        with_failing_store do |store|
          create_resource_action(resource: @resource, name: 'export')
          ManagedIndex.managed_action?('Customer', 'export')
          store.write("pf:#{ManagedIndex::CACHE_KEY}", { 'Customer' => [] })
          first = ManagedIndex.send(:cache_key)
          store.fail_when = ->(operation, name) { operation == :delete && name == first }
          store.raise_instead = true

          assert_equal false, ManagedIndex.invalidate!

          assert_equal([[first, ManagedIndex::CACHE_KEY]], @reported.map { |failure| failure[:keys] }, 'the keys of the invalidation')
          assert_equal 'the cache server is gone', @reported.first[:error].message
          assert_nil store.read("pf:#{ManagedIndex::CACHE_KEY}"), 'the key after the one that raised was still removed'
        end
      end

      # --- a build that races an invalidation (the reviewer's P1-a) ------------------------
      #
      # A request reads the rows, a commit drops the index, and only then does
      # the request store what it read. Without a check that index — without
      # the new action — would be served to everybody until it expires, and
      # under unconfigured_action_strategy :allow the action would run without
      # a grant. The commit runs at exactly that point.

      test 'a commit between the rows read and the index stored leaves no index without the new action' do
        returned = nil

        writes = interrupting_index_writes(-> { create_resource_action(resource: @resource, name: 'export') }) do
          returned = ManagedIndex.managed_action?('Customer', 'export')
        end

        ManagedIndex::RequestMemo.reset
        assert ManagedIndex.managed_action?('Customer', 'export'), 'the next request sees the action as managed'
        assert_equal 2, writes, 'the index was built once more'
        assert returned, 'the request that raced gets what it built the second time'
      end

      test 'a rebuild overtaken twice leaves nothing in the cache' do
        first = -> { create_resource_action(resource: @resource, name: 'export') }
        second = -> { create_resource_action(resource: @resource, name: 'merge') }

        writes = interrupting_index_writes(first, second) { ManagedIndex.managed_actions('Customer') }

        assert_equal 2, writes, 'no third attempt'
        assert_nil cached_index, 'an index built across an invalidation is not left in the cache'
        ManagedIndex::RequestMemo.reset
        assert_equal %w[export merge], ManagedIndex.managed_actions('Customer').sort
      end

      # The other process's commit does not clear this request's query cache,
      # so the row is changed behind it, through the database driver.
      test 'the repeated build reads the rows again, not the query cache of the request' do
        action = create_resource_action(resource: @resource, name: 'export', is_active: false)
        commit_elsewhere = lambda do
          change_behind_the_query_cache(action, is_active: true)
          ManagedIndex.invalidate!
        end

        ActiveRecord::Base.cache do
          PermissionForge::ResourceAction.in_effect.to_a # the request has read the rows before
          writes = interrupting_index_writes(commit_elsewhere) { ManagedIndex.managed_resource?('Customer') }

          ManagedIndex::RequestMemo.reset
          assert ManagedIndex.managed_action?('Customer', 'export'), 'the next request sees the action as managed'
          assert_equal 2, writes
        end
      end

      test 'a plain build reads the stamp twice and stores once; an invalidation stamps before it removes' do
        key = ManagedIndex.send(:cache_key)
        stamp = ManagedIndex::STAMP_KEY

        with_failing_store do |store|
          ManagedIndex.managed_resource?('Customer')
          assert_equal [[:read, key], [:read, stamp], [:write, stamp], [:read, stamp], [:write, key], [:read, stamp]],
                       store.operations, 'no stamp yet: the build writes one first'

          store.operations.clear
          ManagedIndex.invalidate!
          # nothing under the tenant-less key: the store cannot tell that from a failed delete (Cache::Base#expunge)
          assert_equal [[:write, stamp], [:delete, key], [:delete, ManagedIndex::CACHE_KEY], [:write, ManagedIndex::CACHE_KEY]],
                       store.operations
        end
      end

      test 'building the index leaves the notice about withheld permission rebuilds alone' do
        notice = PermissionForge::Cache::WithheldNotice
        notice.withheld

        ManagedIndex.managed_resource?('Customer')

        assert_equal 1, notice.instance_variable_get(:@in_a_row), 'not a permission rebuild'
      end

      # --- a removal the store does not confirm (the reviewer's P1-b) ------------------------

      test 'a removal the store does not confirm at first is tried again, and nothing is reported' do
        with_failing_store do |store|
          ManagedIndex.managed_resource?('Customer')
          key = ManagedIndex.send(:cache_key)
          lost = 0
          store.fail_when = ->(operation, name) { name == key && %i[delete write].include?(operation) && (lost += 1) <= 2 }

          assert ManagedIndex.invalidate!

          assert_nil cached_index
          assert_empty @reported
          assert_empty PermissionForge::Cache::Invalidation.backlog
        end
      end

      test 'while a removal is owed this process builds the index instead of reading the one that should be gone' do
        with_failing_store do |store|
          ManagedIndex.managed_resource?('Customer') # cached: Customer, no actions
          key = ManagedIndex.send(:cache_key)
          store.fail_when = ->(operation, name) { name == key && %i[delete write].include?(operation) }

          create_resource_action(resource: @resource, name: 'export')

          assert_equal([:invalidate], @reported.map { |failure| failure[:operation] })
          assert PermissionForge::Cache::Invalidation.owed?(ManagedIndex::STAMP_KEY)
          store.up!
          assert_equal({ Customer: [] }, cached_index, 'the index that could not be removed is back in reach')

          store.operations.clear
          ManagedIndex::RequestMemo.reset
          assert ManagedIndex.managed_action?('Customer', 'export'), 'within the window in which nothing is tried again'
          assert_not_includes store.operations, [:read, key]
          assert_includes cached_index[:Customer], 'export', 'the build replaced the entry'
        end
      end

      test 'what is owed is made once the store answers again' do
        with_failing_store do |store|
          ManagedIndex.managed_resource?('Customer')
          key = ManagedIndex.send(:cache_key)
          store.fail_when = ->(operation, name) { name == key && %i[delete write].include?(operation) }
          create_resource_action(resource: @resource, name: 'export')
          store.up!
          @reported.clear

          PermissionForge::Cache::Invalidation.store_answered! # the window has passed
          ManagedIndex::RequestMemo.reset
          assert ManagedIndex.managed_action?('Customer', 'export')

          assert_empty PermissionForge::Cache::Invalidation.backlog
          assert_empty @reported, 'making what was owed is nothing to report'
        end
      end

      test 'an owed removal is not made from inside an open transaction, where the index is still not read from the store' do
        with_failing_store do |store|
          ManagedIndex.managed_resource?('Customer')
          key = ManagedIndex.send(:cache_key)
          store.fail_when = ->(operation, name) { name == key && %i[delete write].include?(operation) }
          create_resource_action(resource: @resource, name: 'export')
          store.up!
          PermissionForge::Cache::Invalidation.store_answered!
          store.operations.clear

          ActiveRecord::Base.transaction do
            ManagedIndex::RequestMemo.reset
            assert ManagedIndex.managed_action?('Customer', 'export')
          end

          assert_empty store.operations, 'neither read, nor written, nor removed'
          assert PermissionForge::Cache::Invalidation.backlog.include?(ManagedIndex::STAMP_KEY)
        end
      end

      # --- inside a transaction ----------------------------------------------------------

      # The reviewer's G1: uncommitted rows are visible to their own
      # transaction at every isolation level, so this does not depend on
      # config.snapshot_transactions.
      test 'an index built inside a transaction is not written to the shared cache' do
        [true, false].each do |snapshots|
          PermissionForge.configuration.snapshot_transactions = snapshots
          action = create_resource_action(resource: @resource, name: "export_#{snapshots}")
          assert ManagedIndex.managed_action?('Customer', action.name)
          ManagedIndex.invalidate! # its 60 seconds are over

          ActiveRecord::Base.transaction do
            action.update!(is_active: false) # an edit that will not be committed
            assert_not ManagedIndex.managed_action?('Customer', action.name), 'the transaction sees its own rows'
            assert_nil cached_index
            raise ActiveRecord::Rollback
          end

          assert_nil cached_index
          assert ManagedIndex.managed_action?('Customer', action.name), 'and the request does not keep its copy past the rollback'
          assert_not_nil cached_index
        end
      end

      test 'a cached index is read inside a transaction as usual, and one built outside is stored' do
        create_resource_action(resource: @resource, name: 'export')
        assert ManagedIndex.managed_action?('Customer', 'export')

        reads = count_cache_reads do
          ActiveRecord::Base.transaction do
            ManagedIndex::RequestMemo.reset
            assert ManagedIndex.managed_action?('Customer', 'export')
          end
        end

        assert_equal 1, reads
        assert_not_nil cached_index
      end

      # The reviewer's G3: Rails runs the commit callbacks of what is saved
      # inside a non-joinable transaction at the savepoint release. A request
      # that builds the index between that and the COMMIT caches it without
      # the new row, so the drop is repeated after the COMMIT.
      test 'a drop made inside an open transaction is repeated after the outermost commit' do
        stale = { 'Customer' => [] }
        drops = []
        original = ManagedIndex.method(:invalidate!)
        replace_singleton_method(ManagedIndex, :invalidate!) do |tenant_id: nil|
          drops << ActiveRecord::Base.connection.open_transactions
          original.call(tenant_id: tenant_id)
        end

        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true, joinable: false) { create_resource_action(resource: @resource, name: 'export') }
          PermissionForge.cache.write(ManagedIndex.send(:cache_key), stale) # another request, before the COMMIT
        end

        assert_equal [3, 1], drops, 'at the savepoint release (the test transaction, the outer one, the non-joinable one), then after the commit'
        assert_nil cached_index
        ManagedIndex::RequestMemo.reset
        assert ManagedIndex.managed_action?('Customer', 'export')
      ensure
        replace_singleton_method(ManagedIndex, :invalidate!, original)
      end

      test 'a drop inside a transaction that rolls back is not repeated' do
        drops = 0
        original = ManagedIndex.method(:invalidate!)
        replace_singleton_method(ManagedIndex, :invalidate!) do |tenant_id: nil|
          drops += 1
          original.call(tenant_id: tenant_id)
        end

        ActiveRecord::Base.transaction do
          ManagedIndex.invalidate!
          ManagedIndex.invalidate!
          raise ActiveRecord::Rollback
        end
        assert_equal 2, drops

        ActiveRecord::Base.transaction { 2.times { ManagedIndex.invalidate! } }
        assert_equal 5, drops, 'twice inside, once after the commit'
      ensure
        replace_singleton_method(ManagedIndex, :invalidate!, original)
      end

      test 'many lookups in one request cost one cache read' do
        create_resource_action(resource: @resource, name: 'export')
        reads = count_cache_reads do
          50.times do
            ManagedIndex.managed_actions('Customer')
            ManagedIndex.managed_action?('Customer', 'merge')
            ManagedIndex.managed_resource?('Supplier')
          end
        end

        assert_equal 1, reads
      end

      # A job that invalidates many users and asks the guard in between bumps
      # the cache version each time: one copy per version was kept until the
      # executor reset (pre-release performance review MINOR-2).
      test 'a request keeps one copy per cache key, whatever the cache version bumps' do
        ManagedIndex::RequestMemo.reset
        50.times do
          PermissionForge.bump_permissions_cache_version!
          ManagedIndex.managed_resource?('Customer')
        end

        assert_equal [ManagedIndex.send(:cache_key)], ManagedIndex::RequestMemo.indexes.keys
      end

      test 'a cache version bump makes the request read the index again' do
        ManagedIndex.managed_resource?('Customer')
        PermissionForge::ResourceAction.insert_all!([action_row('export')])
        ManagedIndex.send(:cache_key).then { |key| PermissionForge.cache.delete(key) }

        assert_not ManagedIndex.managed_action?('Customer', 'export'), 'still the request copy'

        PermissionForge.bump_permissions_cache_version!
        assert ManagedIndex.managed_action?('Customer', 'export')
      end

      test 'the request copy is re-read once it is older than MAX_TTL' do
        ManagedIndex.managed_resource?('Customer')
        PermissionForge::ResourceAction.insert_all!([action_row('export')])
        ManagedIndex.send(:cache_key).then { |key| PermissionForge.cache.delete(key) }

        assert_not ManagedIndex.managed_action?('Customer', 'export'), 'still the request copy'

        travel(ManagedIndex::MAX_TTL + 1) do
          assert ManagedIndex.managed_action?('Customer', 'export')
        end
      end

      test 'the cached index never outlives MAX_TTL, whatever cache_ttl is' do
        [3600, nil, 30].each do |cache_ttl|
          PermissionForge.configuration.cache_ttl = cache_ttl

          assert_equal [cache_ttl, ManagedIndex::MAX_TTL].compact.min, ManagedIndex.send(:ttl)
        end
      end

      test 'creating or renaming a Permission Set, or adding an inactive row, leaves the index in place' do
        ManagedIndex.managed_resource?('Customer')
        assert_not_nil cached_index

        other = create_permission_set(name: 'Another set')
        other.update!(name: 'Renamed')
        create_resource_action(resource: @resource, name: 'export', is_active: false)
        create_resource(permission_set: @set, name: 'Order', is_active: false)

        assert_not_nil cached_index
      end

      test 'flag edits leave the cached index in place' do
        action = create_resource_action(resource: @resource, name: 'export')
        ManagedIndex.managed_resource?('Customer')
        assert_not_nil cached_index

        action.update!(is_permitted: true)
        @resource.update!(create_access: true)
        @set.update!(description: 'changed')

        assert_not_nil cached_index
      end

      test 'the index is scoped to the current tenant' do
        create_resource_action(resource: @resource, name: 'export')
        assert ManagedIndex.managed_action?('Customer', 'export')

        other = Account.create!(name: 'Other Account')
        within(other) do
          assert_not ManagedIndex.managed_resource?('Customer')
          assert_not ManagedIndex.managed_action?('Customer', 'export')

          set = create_permission_set
          create_resource_action(resource: create_resource(permission_set: set, name: 'Supplier'), name: 'sync')
          assert ManagedIndex.managed_action?('Supplier', 'sync')
        end

        assert_not ManagedIndex.managed_resource?('Supplier')
        assert ManagedIndex.managed_action?('Customer', 'export')
      end

      test 'a change made with no ambient tenant drops that record tenant index' do
        action = create_resource_action(resource: @resource, name: 'export')
        assert ManagedIndex.managed_action?('Customer', 'export')

        tenant = DEFAULT_TEST_ACCOUNT
        no_tenant!
        action.update!(is_active: false)
        ActsAsTenant.test_tenant = tenant

        assert_not ManagedIndex.managed_action?('Customer', 'export')
      end

      test 'works with a cache that stores nothing' do
        original = PermissionForge.configuration.cache_backend
        PermissionForge.configure { |config| config.cache_backend = :null }
        create_resource_action(resource: @resource, name: 'export')

        assert ManagedIndex.managed_action?('Customer', 'export')
      ensure
        PermissionForge.configure { |config| config.cache_backend = original }
      end
    end
  end
end
