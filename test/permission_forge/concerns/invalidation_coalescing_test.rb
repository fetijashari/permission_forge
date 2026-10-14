# frozen_string_literal: true

require 'test_helper'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module Concerns
    # One committed transaction invalidates each affected user once — and never
    # skips a user because of something that happened before that commit.
    #
    # Every test counts the calls to the public User#invalidate_permissions
    # (host apps override it) and checks the cached hashes are gone afterwards.
    # Tests run inside the wrapping test transaction, which is not joinable: a
    # transaction opened in a test commits, and runs its commit callbacks, the
    # way a top-level one does in production.
    class InvalidationCoalescingTest < ActiveSupport::TestCase
      include PermissionForge::Tenancy::TenancyTestHelper

      # A field row whose own callbacks run test code: after_commit before
      # (prepended) and after (appended) the gem's invalidation, and a
      # before_save that can halt the save once the gem's callbacks have run.
      class HookedField < PermissionForge::ResourceField
        class_attribute :before_invalidation, :after_invalidation, :halt_saves

        before_save { throw :abort if halt_saves }
        after_commit(prepend: true) { before_invalidation&.call }
        after_commit { after_invalidation&.call }
      end

      setup do
        @set = create_permission_set(name: 'Coalesced')
        @users = Array.new(3) { |i| create_user(name: "Person #{i}") }
        @users.each { |user| create_permission_set_user(user: user, permission_set: @set) }
        @resource = create_resource(permission_set: @set, name: 'Customer')
        @name = create_resource_field(resource: @resource, name: 'name')
        @email = create_resource_field(resource: @resource, name: 'email')
        warm
      end

      teardown do
        HookedField.before_invalidation = HookedField.after_invalidation = HookedField.halt_saves = nil
      end

      # --- one transaction, one invalidation per user --------------------------

      test 'a single save outside a transaction invalidates each assigned user once' do
        calls = recording_invalidations { @name.update!(edit_access: true) }

        assert_each_user_once calls
        assert_none_cached
      end

      test 'every kind of record written in one transaction invalidates each user once' do
        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            @set.update!(description: 'changed')
            @resource.update!(create_access: true)
            [@name, @email].each { |field| field.update!(edit_access: true) }
            create_resource_field(resource: @resource, name: 'domain')
            create_resource_action(resource: @resource, name: 'export', is_permitted: true)
            create_permission_set_rule(permission_set: @set, resource: @resource)
          end
        end

        assert_each_user_once calls
        assert_none_cached
        assert @users.first.field_permissions(:Customer, :name)[:edit_access]
      end

      test 'nothing is invalidated before the transaction commits' do
        calls = recording_invalidations do |seen|
          ActiveRecord::Base.transaction do
            @name.update!(edit_access: true)
            @resource.update!(create_access: true)

            assert_empty seen
            assert_all_cached
          end
        end

        assert_each_user_once calls
      end

      test 'records of one Permission Set share the affected-user lookup' do
        other = create_resource(permission_set: @set, name: 'Supplier')
        fields = Array.new(6) { |i| create_resource_field(resource: i.even? ? @resource : other, name: "column_#{i}") }

        statements = capturing_sql do
          ActiveRecord::Base.transaction do
            @set.update!(description: 'changed')
            fields.each { |field| field.update!(edit_access: true) }
          end
        end

        assert_equal 1, statements.grep(/FROM ["`]permission_set_users["`]/).size, 'one assignment lookup per set'
        assert_empty statements.grep(/FROM ["`]users["`]/), 'the holders are invalidated by id, none is loaded'
        assert_equal 2, statements.grep(/SELECT ["`]resources["`]\.["`]permission_set_id["`]/).size, 'one per resource'
      end

      test 'records of one Permission Set load the assigned users together where the host overrides the invalidation' do
        fields = Array.new(4) { |i| create_resource_field(resource: @resource, name: "column_#{i}") }

        statements = nil
        calls = recording_invalidations do
          statements = capturing_sql do
            ActiveRecord::Base.transaction { fields.each { |field| field.update!(edit_access: true) } }
          end
        end

        assert_each_user_once calls
        assert_equal 1, statements.grep(/FROM ["`]users["`]/).size, 'the assigned users are loaded together'
      end

      test 'two Permission Sets written in one transaction invalidate a shared user once' do
        other_set = create_permission_set(name: 'Second')
        other_resource = create_resource(permission_set: other_set, name: 'Supplier')
        create_permission_set_user(user: @users.first, permission_set: other_set)
        warm

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            @resource.update!(create_access: true)
            other_resource.update!(create_access: true)
          end
        end

        assert_each_user_once calls
        assert_none_cached
      end

      test 'a Permission Set Group and its sets written in one transaction invalidate each user once' do
        group = create_permission_set_group(name: 'Grouped')
        @set.update!(permission_set_group_id: group.id)
        warm

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            group.update!(description: 'changed')
            @set.update!(description: 'changed')
            @resource.update!(create_access: true)
          end
        end

        assert_each_user_once calls
        assert_none_cached
      end

      test 'Review and save in the admin invalidates each user once' do
        params = { set: { description: 'Reviewed' },
                   resources: { @resource.id.to_s => { read_access: '1', create_access: '1' } },
                   fields: { @name.id.to_s => { level: 'hidden' }, @email.id.to_s => { level: 'hidden' } } }
        change_set = PermissionForge::Admin::ChangeSet.new(permission_set: @set, params: params)
        assert_operator change_set.changes.map(&:record).uniq.size, :>=, 4

        calls = recording_invalidations { change_set.apply! }

        assert_each_user_once calls
        assert_none_cached
        assert @users.first.can_create?(:Customer)
      end

      # Rails runs the commit callbacks of one instance per row: the other
      # instance never sees its after_commit and keeps the batch it joined.
      test 'two instances of one row written in a transaction invalidate each user once' do
        twin = PermissionForge::ResourceField.find(@name.id)

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            @name.update!(edit_access: true)
            twin.update!(label: 'Full name')
          end
        end
        assert_each_user_once calls
        assert_none_cached
        kept = [@name, twin].count { |instance| instance.instance_variable_get(:@pf_joined_invalidation_batch) }
        assert_equal 1, kept, 'precondition: one instance never ran its after_commit'

        [@name, twin].each do |instance|
          warm
          later = recording_invalidations { instance.reload.update!(description: "by #{instance.object_id}") }

          assert_each_user_once later
          assert_none_cached
        end
      end

      # --- records moved to another set -----------------------------------------

      test 'a resource moved to another Permission Set invalidates the users of both sets' do
        other_set = create_permission_set(name: 'Second')
        newcomer = create_user(name: 'Only in the second set')
        create_permission_set_user(user: newcomer, permission_set: other_set)
        @users << newcomer
        warm

        calls = recording_invalidations { @resource.update!(permission_set_id: other_set.id) }

        assert_each_user_once calls
        assert_none_cached
        assert_not @users.first.can_read?(:Customer)
        assert newcomer.can_read?(:Customer)
      end

      test 'a field moved to a resource of another Permission Set invalidates the users of both sets' do
        other_set = create_permission_set(name: 'Second')
        other_resource = create_resource(permission_set: other_set, name: 'Customer')
        newcomer = create_user(name: 'Only in the second set')
        create_permission_set_user(user: newcomer, permission_set: other_set)
        @users << newcomer
        warm

        calls = recording_invalidations { @email.update!(resource_id: other_resource.id) }

        assert_each_user_once calls
        assert_none_cached
        assert_nil @users.first.field_permissions(:Customer, :email)
        assert newcomer.field_permissions(:Customer, :email)
      end

      # --- successive transactions ---------------------------------------------

      test 'the same record saved in two successive transactions invalidates after each' do
        first = recording_invalidations { ActiveRecord::Base.transaction { @name.update!(edit_access: true) } }
        warm
        second = recording_invalidations { ActiveRecord::Base.transaction { @name.update!(edit_access: false) } }

        assert_each_user_once first
        assert_each_user_once second
        assert_none_cached
        assert_not @users.first.field_permissions(:Customer, :name)[:edit_access]
      end

      test 'successive saves without a transaction each invalidate' do
        calls = recording_invalidations do
          @name.update!(edit_access: true)
          warm
          @email.update!(edit_access: true)
          assert_none_cached
          warm
          @name.update!(edit_access: false)
        end

        assert_equal @users.size * 3, calls.size
        assert_none_cached
      end

      # --- nested transactions and savepoints ----------------------------------

      test 'a committed savepoint invalidates once, after the outer commit' do
        calls = recording_invalidations do |seen|
          ActiveRecord::Base.transaction do
            @name.update!(edit_access: true)
            ActiveRecord::Base.transaction(requires_new: true) { @email.update!(edit_access: true) }

            assert_empty seen, 'a released savepoint is not a commit'
            assert_all_cached
          end
        end

        assert_each_user_once calls
        assert_none_cached
      end

      test 'an inner rollback followed by more writes invalidates once, after the outer commit' do
        calls = recording_invalidations do |seen|
          ActiveRecord::Base.transaction do
            @name.update!(edit_access: true)
            ActiveRecord::Base.transaction(requires_new: true) do
              @email.update!(edit_access: true)
              raise ActiveRecord::Rollback
            end
            assert_empty seen
            @resource.update!(create_access: true)
            @email.update!(label: 'E-mail')
          end
        end

        assert_each_user_once calls
        assert_none_cached
        fields = @users.first.permissions_hash.dig(:permissions, :resources, :Customer, :fields)
        assert fields.dig(:name, :edit_access)
        assert_not fields.dig(:email, :edit_access), 'the rolled-back change was not committed'
      end

      test 'a rolled-back savepoint alone still leaves the outer commit invalidating' do
        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            ActiveRecord::Base.transaction(requires_new: true) do
              @email.update!(edit_access: true)
              raise ActiveRecord::Rollback
            end
            @name.update!(edit_access: true)
          end
        end

        assert_each_user_once calls
        assert_none_cached
      end

      # A transaction nested in a non-joinable one commits, and runs its commit
      # callbacks, while the outer transaction is still open. What it
      # invalidated says nothing about the outer commit: a hash rebuilt in
      # between holds the outer transaction's uncommitted-then-committed rows.
      test 'an inner commit inside an open transaction never covers the outer commit' do
        PermissionForge.configuration.snapshot_transactions = false
        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            @name.update!(edit_access: true)
            ActiveRecord::Base.transaction(requires_new: true, joinable: false) { @email.update!(edit_access: true) }
            cache_something_for_everyone
          end
        end

        assert_none_cached
        assert_equal @users.size * 2, calls.size, 'once for the inner commit, once for the outer'
      end

      # The same without a record of the outer transaction to repair it: the
      # inner record's invalidation runs at the savepoint release, before the
      # COMMIT anyone else can see. Where transactions read from a snapshot,
      # an invalidation made inside an open transaction is made again once
      # that transaction has committed (Cache::Settlement).
      test 'a commit inside a non-joinable transaction nested in an ordinary one is invalidated again after the outer commit' do
        PermissionForge.configuration.snapshot_transactions = true
        calls = recording_invalidations do |made|
          ActiveRecord::Base.transaction do
            ActiveRecord::Base.transaction(requires_new: true, joinable: false) { @email.update!(edit_access: true) }
            assert_each_user_once made
            cache_something_for_everyone
          end
        end

        assert_none_cached
        assert_equal @users.size * 2, calls.size
      end

      # Known limit, as it was before the transaction rule: where a
      # transaction is not treated as a snapshot (PostgreSQL at READ
      # COMMITTED) nothing is repeated after the commit.
      test 'without snapshot transactions the nested non-joinable commit is invalidated once, before the outer commit' do
        PermissionForge.configuration.snapshot_transactions = false
        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            ActiveRecord::Base.transaction(requires_new: true, joinable: false) { @email.update!(edit_access: true) }
            cache_something_for_everyone
          end
        end

        assert_each_user_once calls
        assert_all_cached
      end

      test 'a nested non-joinable commit whose outer transaction rolls back is not invalidated again' do
        PermissionForge.configuration.snapshot_transactions = true
        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            ActiveRecord::Base.transaction(requires_new: true, joinable: false) { @email.update!(edit_access: true) }
            raise ActiveRecord::Rollback
          end
        end

        assert_each_user_once calls
      end

      # --- rollbacks and exceptions ----------------------------------------------

      test 'a rolled-back transaction invalidates nothing and the next commit invalidates' do
        rolled_back = recording_invalidations do
          ActiveRecord::Base.transaction do
            @name.update!(edit_access: true)
            @resource.update!(create_access: true)
            raise ActiveRecord::Rollback
          end
        end
        assert_empty rolled_back
        assert_all_cached

        committed = recording_invalidations { ActiveRecord::Base.transaction { @name.update!(edit_access: true) } }

        assert_each_user_once committed
        assert_none_cached
      end

      test 'an exception inside the transaction invalidates nothing and the next commit invalidates' do
        raised = recording_invalidations do
          assert_raises(RuntimeError) do
            ActiveRecord::Base.transaction do
              @name.update!(edit_access: true)
              raise 'boom'
            end
          end
        end
        assert_empty raised
        assert_all_cached

        committed = recording_invalidations { @email.update!(edit_access: true) }

        assert_each_user_once committed
        assert_none_cached
      end

      test 'a failed save leaves nothing behind for the next commit to trust' do
        @name.mask_access = true
        @name.mask_strategy = 'no_such_strategy'
        assert_not @name.save
        @name.reload

        calls = recording_invalidations { @name.update!(edit_access: true) }

        assert_each_user_once calls
        assert_none_cached
      end

      # --- destroy ---------------------------------------------------------------

      test 'destroying a Permission Set invalidates each assigned user once' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        create_permission_set_rule(permission_set: @set, resource: @resource)
        warm

        calls = recording_invalidations { @set.destroy! }

        assert_each_user_once calls
        assert_none_cached
        assert_not @users.first.can_read?(:Customer)
      end

      test 'destroying a resource with its fields, actions and rules invalidates each user once' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        create_permission_set_rule(permission_set: @set, resource: @resource)
        warm

        calls = recording_invalidations { @resource.destroy! }

        assert_each_user_once calls
        assert_none_cached
      end

      test 'a record created and destroyed in one transaction still invalidates' do
        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            create_resource_field(resource: @resource, name: 'domain').destroy!
            @name.destroy!
          end
        end

        assert_each_user_once calls
        assert_none_cached
      end

      # --- assignments -----------------------------------------------------------

      test 'assigning a person to several sets in one transaction invalidates them once' do
        newcomer = create_user(name: 'New')
        sets = Array.new(3) { |i| create_permission_set(name: "Extra #{i}") }
        newcomer.permissions_hash

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            sets.each { |set| create_permission_set_user(user: newcomer, permission_set: set) }
          end
        end

        assert_equal [newcomer.id], calls.map(&:first)
        assert_nil PermissionForge.cache.read(newcomer.permission_cache_key)
      end

      test 'an assignment and an edit of the same set in one transaction invalidate each user once' do
        newcomer = create_user(name: 'New')
        newcomer.permissions_hash

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            create_permission_set_user(user: newcomer, permission_set: @set)
            @resource.update!(create_access: true)
          end
        end

        assert_equal (@users + [newcomer]).map(&:id).sort, calls.map(&:first).sort
        assert newcomer.can_create?(:Customer)
      end

      test 'an assignment built with its user invalidates that user without loading it again' do
        newcomer = create_user(name: 'New')
        newcomer.permissions_hash

        statements = capturing_sql(after_commit: true) { create_permission_set_user(user: newcomer, permission_set: @set) }

        assert_empty(statements.grep(/FROM .users./i))
        assert_nil PermissionForge.cache.read(newcomer.permission_cache_key)
      end

      test 'an assignment loaded without its user invalidates it by id' do
        assignment = PermissionForge::PermissionSetUser.find_by!(user_id: @users.first.id, permission_set_id: @set.id)

        statements = capturing_sql(after_commit: true) { assignment.destroy! }

        assert_empty statements.grep(/FROM .users./i)
        assert_not cached?(@users.first)
      end

      test 'an assignment loaded without its user loads the user where the host overrides the invalidation' do
        assignment = PermissionForge::PermissionSetUser.find_by!(user_id: @users.first.id, permission_set_id: @set.id)

        statements = nil
        calls = recording_invalidations { statements = capturing_sql(after_commit: true) { assignment.destroy! } }

        assert_equal [[@users.first.id, assignment.account_id]], calls
        assert_equal 1, statements.grep(/FROM .users./i).size
        assert_not cached?(@users.first)
      end

      test 'revoking an assignment invalidates after each commit' do
        assignment = PermissionForge::PermissionSetUser.find_by!(user_id: @users.first.id, permission_set_id: @set.id)

        calls = recording_invalidations do
          assignment.update!(expires_at: 1.day.from_now)
          warm
          assignment.destroy!
        end

        assert_equal [@users.first.id] * 2, calls.map(&:first)
        assert_not @users.first.can_read?(:Customer)
      end

      # --- writes made by after_commit callbacks -------------------------------

      # A permission record written between two after_commits of one commit
      # makes the batch forget: the record still waiting invalidates again,
      # after that write, as it did before there were batches.
      test 'a write made by a callback between two after_commits is followed by another invalidation' do
        hooked = HookedField.find(@name.id)
        HookedField.after_invalidation = lambda do
          @email.update!(edit_access: true)
          assert_none_cached 'the nested commit invalidated on its own'
          warm
        end

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            hooked.update!(edit_access: true)
            @resource.update!(create_access: true)
          end
        end

        assert_equal @users.size * 3, calls.size, 'the first record, the nested commit, the record still waiting'
        assert_none_cached
        fields = @users.first.permissions_hash.dig(:permissions, :resources, :Customer, :fields)
        assert fields.dig(:email, :edit_access)
      end

      # The nested transaction is not joinable: the write inside it runs its
      # commit callbacks at the savepoint release, before the COMMIT anyone
      # else can see. A hash another request rebuilds in between is stale, and
      # only the record still waiting can repair it.
      test 'a write in a non-joinable transaction between two after_commits is followed by another invalidation' do
        hooked = HookedField.find(@name.id)
        HookedField.after_invalidation = lambda do
          ActiveRecord::Base.transaction(joinable: false) do
            @email.update!(edit_access: true)
            cache_something_for_everyone
          end
        end

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            hooked.update!(edit_access: true)
            @resource.update!(create_access: true)
          end
        end

        assert_equal @users.size * 3, calls.size
        assert_none_cached
      end

      # The write need not be made by the fiber (or thread) the commit runs on.
      # (A thread cannot be tried here: it would wait for the test's one
      # connection, which the commit holds.)
      test 'a write made in another fiber between two after_commits is followed by another invalidation' do
        hooked = HookedField.find(@name.id)
        HookedField.after_invalidation = lambda do
          Fiber.new { ActiveRecord::Base.transaction(joinable: false) { @email.update!(edit_access: true) } }.resume
          warm
        end

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            hooked.update!(edit_access: true)
            @resource.update!(create_access: true)
          end
        end

        assert_equal @users.size * 3, calls.size
        assert_none_cached
      end

      test 'a touch between two after_commits is followed by another invalidation' do
        hooked = HookedField.find(@name.id)
        HookedField.after_invalidation = lambda do
          @email.touch
          warm
        end

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            hooked.update!(edit_access: true)
            @resource.update!(create_access: true)
          end
        end

        assert_equal @users.size * 3, calls.size
        assert_none_cached
      end

      test 'a write between two after_commits also repeats the affected-user lookup' do
        newcomer = create_user(name: 'New')
        newcomer.permissions_hash
        hooked = HookedField.find(@name.id)
        HookedField.after_invalidation = lambda do
          create_permission_set_user(user: newcomer, permission_set: @set)
          newcomer.permissions_hash
        end

        ActiveRecord::Base.transaction do
          hooked.update!(edit_access: true)
          @resource.update!(create_access: true)
        end

        assert_nil PermissionForge.cache.read(newcomer.permission_cache_key), 'found by the lookup of the record still waiting'
      end

      test 'a write made by a callback that runs before the invalidation is covered' do
        hooked = HookedField.find(@name.id)
        HookedField.before_invalidation = -> { @email.update!(edit_access: true) }

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            hooked.update!(edit_access: true)
            @resource.update!(create_access: true)
          end
        end

        assert_operator calls.size, :>=, @users.size
        assert_none_cached
        fields = @users.first.permissions_hash.dig(:permissions, :resources, :Customer, :fields)
        assert fields.dig(:email, :edit_access)
        assert fields.dig(:name, :edit_access)
      end

      # The nested commit invalidates after both commits, so the outer records
      # have nothing left to do: a hash rebuilt afterwards holds every change.
      test 'a callback that re-saves a record still waiting for its own after_commit loses nothing' do
        hooked = HookedField.find(@name.id)
        HookedField.before_invalidation = lambda do
          HookedField.before_invalidation = nil
          @resource.update!(edit_access: true)
          assert_none_cached 'the nested commit invalidated'
          warm
        end

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            hooked.update!(edit_access: true)
            @resource.update!(create_access: true)
          end
        end

        assert_operator calls.size, :>=, @users.size
        user = @users.first
        assert user.can_edit?(:Customer)
        assert user.can_create?(:Customer)
        assert user.field_permissions(:Customer, :name)[:edit_access]
      end

      # Cache keys follow the ambient tenant: what a nested commit did under
      # another tenant is not reused by the outer commit. (The lookups follow
      # the record's tenant, so the nested commit finds the users as well.)
      test 'a nested commit under another tenant does not answer for the outer commit' do
        other = Account.create!(name: 'Other')
        hooked = HookedField.find(@name.id)
        HookedField.before_invalidation = -> { within(other) { @email.update!(label: 'E-mail') } }

        calls = recording_invalidations do
          ActiveRecord::Base.transaction { hooked.update!(edit_access: true) }
        end

        assert_equal @users.size * 2, calls.size, 'the nested commit under the other tenant, and the outer one'
        assert_none_cached
      end

      # --- touch, and records that keep a batch they never used ----------------

      test 'touch invalidates on its own' do
        calls = recording_invalidations { @name.touch }

        assert_each_user_once calls
        assert_none_cached
      end

      test 'a touch inside a transaction invalidates after the commit' do
        calls = recording_invalidations do |seen|
          ActiveRecord::Base.transaction do
            @name.touch
            @email.update!(edit_access: true)
            assert_empty seen
          end
        end

        assert_operator calls.size, :>=, @users.size
        assert_none_cached
      end

      # A save halted after the gem's before_save writes no row, so no
      # after_commit follows and the record keeps the batch it joined — which
      # the commit of the other record then used.
      test 'a record that kept a used batch does not trust it on a later touch' do
        hooked = record_holding_a_used_batch

        calls = recording_invalidations { hooked.touch }

        assert_each_user_once calls
        assert_none_cached
      end

      test 'a record that kept a used batch joins a new one on its next save' do
        hooked = record_holding_a_used_batch

        calls = recording_invalidations { hooked.update!(edit_access: true) }

        assert_each_user_once calls
        assert_none_cached
      end

      test 'a record that kept a used batch joins a new one when it is destroyed' do
        hooked = record_holding_a_used_batch

        calls = recording_invalidations { hooked.destroy! }

        assert_each_user_once calls
        assert_none_cached
      end

      test 'a save that changes nothing still invalidates' do
        calls = recording_invalidations { @name.save! }

        assert_each_user_once calls
        assert_none_cached
      end

      test 'a committed record keeps no batch' do
        ActiveRecord::Base.transaction do
          @name.update!(edit_access: true)
          @set.update!(description: 'changed')
        end
        assignment = create_permission_set_user(user: create_user, permission_set: @set)

        [@name, @set, assignment].each do |record|
          assert_nil record.instance_variable_get(:@pf_joined_invalidation_batch), record.class.name
          assert_nil record.instance_variable_get(:@pf_invalidation_batch), record.class.name
        end
      end

      test 'calling the invalidation by hand always invalidates' do
        ActiveRecord::Base.transaction do
          @name.update!(edit_access: true)
          @resource.update!(create_access: true)
        end
        warm

        calls = recording_invalidations do
          @name.send(:invalidate_permissions_for_users)
          @resource.send(:invalidate_permissions_for_users)
        end

        assert_equal @users.size * 2, calls.size
        assert_none_cached
      end

      test 'a record written in a transaction can still be marshalled' do
        ActiveRecord::Base.transaction do
          @name.update!(edit_access: true)

          copy = Marshal.load(Marshal.dump(@name))
          assert_equal @name.id, copy.id
        end
      end

      # --- threads ---------------------------------------------------------------

      test 'a commit on another thread invalidates on its own' do
        calls = recording_invalidations do
          ActiveRecord::Base.transaction { @name.update!(edit_access: true) }
          warm
          Thread.new { ActiveRecord::Base.transaction { @email.update!(edit_access: true) } }.join
        end

        assert_equal @users.size * 2, calls.size
        assert_none_cached
      end

      test 'a batch left open on one thread is not joined from another' do
        HookedField.halt_saves = true
        assert_not HookedField.find(@name.id).update(edit_access: true), 'joined, then halted: the batch stays open'
        open_here = PermissionForge::ExecutionState[PermissionForge::InvalidationBatch::THREAD_KEY]
        assert_not_nil open_here

        calls = recording_invalidations do
          Thread.new { ActiveRecord::Base.transaction { @email.update!(edit_access: true) } }.join
        end

        assert_each_user_once calls
        assert_same open_here, PermissionForge::ExecutionState[PermissionForge::InvalidationBatch::THREAD_KEY]
        assert open_here.open_on?(connection)
      end

      # --- tenants -----------------------------------------------------------------

      test 'one transaction over two tenants invalidates each user once per tenant' do
        tenant_a = Account.create!(name: 'Tenant A')
        tenant_b = Account.create!(name: 'Tenant B')
        user = @users.first
        resources = [tenant_a, tenant_b].map do |tenant|
          within(tenant) do
            set = create_permission_set(name: "Set of #{tenant.name}")
            create_permission_set_user(user: user, permission_set: set)
            2.times.map { |i| create_resource(permission_set: set, name: %w[Supplier Account][i]) }
          end
        end
        key_a, key_b = [tenant_a, tenant_b].map { |tenant| within(tenant) { user.permissions_hash && user.permission_cache_key } }
        no_tenant!

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            resources.flatten.each { |resource| resource.update!(create_access: true) }
          end
        end

        assert_equal [[user.id, tenant_a.id], [user.id, tenant_b.id]], calls.sort
        assert_nil PermissionForge.cache.read(key_a)
        assert_nil PermissionForge.cache.read(key_b)
      end

      test 'the record tenant is passed to invalidate_permissions' do
        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            @name.update!(edit_access: true)
            @set.update!(description: 'changed')
          end
        end

        assert_equal [DEFAULT_TEST_ACCOUNT.id], calls.map(&:last).uniq
      end

      # --- managed actions ---------------------------------------------------------

      test 'actions added in one transaction drop the managed-actions index once' do
        index = PermissionForge::ControllerActions::ManagedIndex
        assert_not index.managed_action?('Customer', 'export')

        deleted = recording_cache_deletes do
          ActiveRecord::Base.transaction do
            %w[export merge sync].each { |name| create_resource_action(resource: @resource, name: name) }
            create_resource(permission_set: @set, name: 'Supplier')
          end
        end

        assert_equal 1, deleted.count(index::CACHE_KEY)
        assert_equal %w[export merge sync], index.managed_actions('Customer').sort
        assert index.managed_resource?('Supplier')
      end

      test 'successive commits each drop the managed-actions index' do
        index = PermissionForge::ControllerActions::ManagedIndex

        deleted = recording_cache_deletes do
          create_resource_action(resource: @resource, name: 'export')
          assert index.managed_action?('Customer', 'export')
          create_resource_action(resource: @resource, name: 'merge')
        end

        assert_equal 2, deleted.count(index::CACHE_KEY)
        assert index.managed_action?('Customer', 'merge')
      end

      # --- the measured case -----------------------------------------------------

      test '20 records in a set assigned to 50 people invalidate 50 times' do
        people = Array.new(47) { |i| create_user(name: "Crowd #{i}") }
        people.each { |user| create_permission_set_user(user: user, permission_set: @set) }
        @users += people
        fields = Array.new(18) { |i| create_resource_field(resource: @resource, name: "column_#{i}") } + [@name, @email]
        warm

        statements = nil
        deleted = nil
        calls = recording_invalidations do
          deleted = recording_cache_deletes do
            statements = capturing_sql(after_commit: true) do
              ActiveRecord::Base.transaction { fields.each { |field| field.update!(edit_access: true) } }
            end
          end
        end

        assert_each_user_once calls
        assert_none_cached
        assert_equal 200, deleted.size, 'four keys per person: this entry namespace and the previous one'
        assert_equal 4, statements.size, 'the set of the resource, whether it is active, its assignments, their users'
      end

      private

      def warm
        @users.each(&:permissions_hash)
        assert_all_cached
      end

      # What another process leaves in the cache when it rebuilds. (A rebuild
      # made here, inside the open transaction, is not stored.)
      def cache_something_for_everyone
        @users.each { |user| PermissionForge.cache.write(user.permission_cache_key, { permissions: { resources: {} } }) }
        assert_all_cached
      end

      def cached?(user)
        !PermissionForge.cache.read(user.permission_cache_key).nil?
      end

      def assert_all_cached
        assert @users.all? { |user| cached?(user) }, 'expected every hash to be cached'
      end

      def assert_none_cached(message = 'expected every cached hash to be gone')
        assert @users.none? { |user| cached?(user) }, message
      end

      def assert_each_user_once(calls)
        assert_equal @users.map(&:id).sort, calls.map(&:first).sort
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

      def recording_cache_deletes
        cache = PermissionForge.cache
        deleted = []
        original = cache.method(:delete)
        cache.define_singleton_method(:delete) do |key|
          deleted << key
          original.call(key)
        end
        yield
        deleted
      ensure
        cache.singleton_class.send(:remove_method, :delete)
      end

      # The statements run inside the block; with after_commit, only those
      # that follow the release of the transaction (the invalidation).
      def capturing_sql(after_commit: false)
        statements = []
        subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
          statements << payload[:sql] unless payload[:name] == 'SCHEMA'
        end
        yield
        released = statements.rindex { |sql| sql.match?(/\A(RELEASE SAVEPOINT|COMMIT)/i) }
        after_commit ? statements.drop(released + 1) : statements
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # A record whose save was halted after it joined the transaction's batch,
      # in a transaction whose other record committed through that batch.
      def record_holding_a_used_batch
        hooked = HookedField.find(@name.id)
        HookedField.halt_saves = true
        ActiveRecord::Base.transaction do
          assert_not hooked.update(edit_access: true)
          @email.update!(edit_access: true)
        end
        HookedField.halt_saves = false
        kept = hooked.instance_variable_get(:@pf_joined_invalidation_batch)
        assert kept && !kept.open_on?(connection), 'precondition: the record still references a claimed batch'
        warm
        hooked.reload
      end

      def connection
        ActiveRecord::Base.connection_pool.with_connection { |connection| connection }
      end
    end
  end
end
