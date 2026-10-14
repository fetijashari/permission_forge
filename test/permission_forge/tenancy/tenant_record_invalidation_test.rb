# frozen_string_literal: true

require 'test_helper'
require_relative 'tenancy_test_helper'

module PermissionForge
  module Tenancy
    # A change to a permission record invalidates the users of ITS tenant,
    # whatever tenant is ambient when it is saved or committed: another
    # tenant, or none (a job, the console).
    class TenantRecordInvalidationTest < ActiveSupport::TestCase
      include TenancyTestHelper

      setup do
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        @shared = create_user(name: 'Shared')
        @only_a = create_user(name: 'Only A')
        @world = [@tenant_a, @tenant_b].to_h do |tenant|
          within(tenant) do
            set = create_permission_set(name: "Set #{tenant.name}")
            create_permission_set_user(user: @shared, permission_set: set)
            create_permission_set_user(user: @only_a, permission_set: set) if tenant == @tenant_a
            resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
            [tenant.id, { set: set, resource: resource, field: create_resource_field(resource: resource, name: 'name') }]
          end
        end
        @a = @world[@tenant_a.id]
        @b = @world[@tenant_b.id]
        warm
      end

      # --- another tenant is ambient ------------------------------------------------

      test 'every kind of record of tenant A saved under tenant B invalidates the users of tenant A' do
        records = within(@tenant_a) do
          [@a[:set], @a[:resource], @a[:field],
           create_resource_action(resource: @a[:resource], name: 'export'),
           create_permission_set_rule(permission_set: @a[:set], resource: @a[:resource])]
        end

        records.each do |record|
          warm
          attribute = record.has_attribute?(:description) ? :description : :failure_message
          calls = recording_invalidations { within(@tenant_b) { record.update!(attribute => "by #{record.class.name}") } }

          assert_equal [[@only_a.id, @tenant_a.id], [@shared.id, @tenant_a.id]].sort, calls.sort, record.class.name
          assert_not cached?(@shared, @tenant_a), record.class.name
          assert_not cached?(@only_a, @tenant_a), record.class.name
        end
      end

      test 'a record of tenant A destroyed under tenant B invalidates the users of tenant A' do
        within(@tenant_b) { @a[:field].destroy! }

        assert_not cached?(@shared, @tenant_a)
        assert_not cached?(@only_a, @tenant_a)
        within(@tenant_a) { assert_nil @shared.field_permissions(:Customer, :name) }
      end

      test 'a group of tenant A saved under tenant B invalidates the users of its sets' do
        group = within(@tenant_a) { create_permission_set_group(name: 'Group A') }
        within(@tenant_a) { @a[:set].update!(permission_set_group_id: group.id) }
        warm

        calls = recording_invalidations { within(@tenant_b) { group.update!(description: 'changed') } }

        assert_equal [@only_a.id, @shared.id].sort, calls.map(&:first).sort
        assert_not cached?(@shared, @tenant_a)
      end

      test 'an assignment of tenant A revoked under tenant B takes effect in tenant A' do
        assignment = PermissionForge::PermissionSetUser.unscoped.find_by!(user_id: @shared.id, permission_set_id: @a[:set].id)

        within(@tenant_b) { assignment.destroy! }

        assert_not cached?(@shared, @tenant_a)
        within(@tenant_a) { assert_not @shared.can_read?(:Customer) }
      end

      test 'one transaction under tenant A with records of both tenants invalidates each user once per tenant' do
        calls = recording_invalidations do
          within(@tenant_a) do
            ActiveRecord::Base.transaction do
              @a[:field].update!(edit_access: true)
              @a[:resource].update!(create_access: true)
              @b[:field].update!(edit_access: true)
              @b[:resource].update!(create_access: true)
            end
          end
        end

        assert_equal [[@only_a.id, @tenant_a.id], [@shared.id, @tenant_a.id], [@shared.id, @tenant_b.id]].sort, calls.sort
        assert_not cached?(@shared, @tenant_a)
        assert_not cached?(@shared, @tenant_b)
        within(@tenant_b) { assert @shared.field_permissions(:Customer, :name)[:edit_access] }
      end

      test 'a tenant that is ambient at the write but not at the commit still gets its users invalidated' do
        ActsAsTenant.test_tenant = @tenant_a
        ActiveRecord::Base.transaction do
          @a[:field].update!(edit_access: true)
          ActsAsTenant.test_tenant = @tenant_b
        end
        ActsAsTenant.test_tenant = nil

        assert_not cached?(@shared, @tenant_a)
        assert_not cached?(@only_a, @tenant_a)
        within(@tenant_a) { assert @shared.field_permissions(:Customer, :name)[:edit_access] }
      end

      # --- no tenant is ambient (a job, the console) ---------------------------------

      test 'with no ambient tenant a change reaches the users of the record tenant, and only them' do
        no_tenant!

        calls = recording_invalidations { @b[:field].update!(edit_access: true) }

        assert_equal [[@shared.id, @tenant_b.id]], calls
        assert_not cached?(@shared, @tenant_b)
        assert cached?(@shared, @tenant_a)
        assert cached?(@only_a, @tenant_a)
      end

      test 'with no ambient tenant and require_tenant on, a change does not raise and still invalidates' do
        no_tenant!
        ActsAsTenant.configuration.require_tenant = true

        assert_nothing_raised { @a[:field].update!(edit_access: true) }

        assert_not cached?(@shared, @tenant_a)
      ensure
        ActsAsTenant.configuration.require_tenant = false
      end

      # --- rows without a tenant, rows of another tenant -----------------------------

      test 'an assignment without a tenant (older than tenancy) is found from any ambient tenant' do
        legacy = create_user(name: 'Legacy')
        row = within(@tenant_a) { create_permission_set_user(user: legacy, permission_set: @a[:set]) }
        row.update_columns(account_id: nil)
        no_tenant!
        legacy.permissions_hash
        assert_not_nil PermissionForge.cache.read(key_of(legacy))

        calls = recording_invalidations { within(@tenant_b) { @a[:field].update!(edit_access: true) } }

        assert_includes calls.map(&:first), legacy.id
        assert_nil PermissionForge.cache.read(key_of(legacy))
      end

      # An assignment row of tenant B that carries the id of tenant A's set
      # belongs to another set wherever ids are only unique per tenant.
      test 'an assignment of another tenant that merely shares the set id is left alone' do
        stranger = create_user(name: 'Stranger')
        row = within(@tenant_b) { create_permission_set_user(user: stranger, permission_set: @b[:set]) }
        row.update_columns(permission_set_id: @a[:set].id)

        [nil, @tenant_a, @tenant_b].each do |ambient|
          calls = recording_invalidations { within(ambient) { @a[:field].update!(label: "under #{ambient&.name}") } }

          assert_not_includes calls.map(&:first), stranger.id, "ambient #{ambient&.name.inspect}"
          assert_equal [@only_a.id, @shared.id].sort, calls.map(&:first).sort
        end
      end

      test 'a record without a tenant looks for its users in every tenant' do
        @a[:set].update_columns(account_id: nil)
        @a[:resource].update_columns(account_id: nil)
        @a[:field].update_columns(account_id: nil)
        field = PermissionForge::ResourceField.unscoped.find(@a[:field].id)

        # (a row without a tenant does not pass acts_as_tenant's validation)
        calls = recording_invalidations { within(@tenant_b) { field.update_attribute(:edit_access, true) } }

        assert_equal [@only_a.id, @shared.id].sort, calls.map(&:first).sort
        assert_equal [nil], calls.map(&:last).uniq
      end

      # --- a table without the tenant column -------------------------------------------

      # The reviewer's N32: an install whose permission table predates the
      # tenant column. A condition on it raises, the error is swallowed in
      # after_commit, and nobody is invalidated.
      test 'a permission table without the tenant column is looked up without it' do
        connection = ActiveRecord::Base.connection
        connection.create_table(:pf_columnless_assignments, force: true) { |t| t.bigint :user_id }
        model = Class.new(ActiveRecord::Base) do
          self.table_name = 'pf_columnless_assignments'
          def self.name = 'PfColumnlessAssignment'
          include PermissionForge::Concerns::HasTenantScoping

          apply_tenant_scoping!
        end
        connection.execute('INSERT INTO pf_columnless_assignments (user_id) VALUES (7)')
        no_tenant!

        assert_predicate model, :tenant_scoping_applied?
        assert_equal [7], model.of_tenant(@tenant_a.id).pluck(:user_id)
        assert_equal [7], model.of_tenant(nil).pluck(:user_id)
      ensure
        connection.drop_table(:pf_columnless_assignments, if_exists: true)
      end

      test 'a table that has the tenant column is narrowed to the tenant and the rows without one' do
        sql = PermissionForge::PermissionSetUser.of_tenant(@tenant_a.id).to_sql

        assert_match(/account_id/, sql)
        assert_no_match(/account_id/, PermissionForge::PermissionSetUser.of_tenant(nil).to_sql)
      end

      # --- a rebuild asked for inside a transaction ---------------------------------

      test 'regenerate_permissions under tenant A inside a transaction is settled for tenant A, whatever is ambient at the commit' do
        PermissionForge.configuration.snapshot_transactions = true
        no_tenant!

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            within(@tenant_a) { User.find(@shared.id).regenerate_permissions }
            assert cached?(@shared, @tenant_a), 'nothing is touched before the commit'
          end
        end

        assert_equal [[@shared.id, @tenant_a.id]], calls
        assert_not cached?(@shared, @tenant_a)
        assert cached?(@shared, @tenant_b)
      end

      test 'invalidate_permissions for a record tenant inside a transaction is repeated for that tenant after the commit' do
        PermissionForge.configuration.snapshot_transactions = true
        no_tenant!

        calls = recording_invalidations do
          ActiveRecord::Base.transaction do
            User.find(@shared.id).invalidate_permissions(tenant_id: @tenant_b.id)
            PermissionForge.cache.write(key_of(@shared, @tenant_b), { permissions: {} })
          end
        end

        assert_equal [[@shared.id, @tenant_b.id]] * 2, calls
        assert_not cached?(@shared, @tenant_b)
        assert cached?(@shared, @tenant_a)
      end

      # --- the host's user model ---------------------------------------------------

      test 'a default scope on the user model does not hide the holder of an assignment' do
        scopes = User.default_scopes
        User.send(:default_scope) { where(deactivated: true) }

        calls = recording_invalidations { within(@tenant_b) { @a[:field].update!(edit_access: true) } }

        assert_equal [@only_a.id, @shared.id].sort, calls.map(&:first).sort
      ensure
        User.default_scopes = scopes
      end

      # --- acts_as_tenant state is left alone ---------------------------------------

      test 'an invalidation leaves the ambient tenant as it found it' do
        no_tenant!
        @a[:field].update!(edit_access: true)
        assert_nil ActsAsTenant.current_tenant

        within(@tenant_b) do
          @a[:field].update!(edit_access: false)
          assert_equal @tenant_b, ActsAsTenant.current_tenant
          assert_nil ActsAsTenant::Current.current_tenant, 'nothing was written into the request-level tenant'
        end
      end

      private

      def warm
        within(@tenant_a) { [@shared, @only_a].each { |user| User.find(user.id).permissions_hash } }
        within(@tenant_b) { User.find(@shared.id).permissions_hash }
      end

      def cached?(user, tenant)
        !PermissionForge.cache.read(key_of(user, tenant)).nil?
      end

      # The base entry key of `user` in `tenant` (nil: the tenant-agnostic key).
      def key_of(user, tenant = nil)
        PermissionForge::Cache::UserKeys.hash_key(user.id, tenant&.id)
      end

      def recording_invalidations
        calls = []
        User.define_method(:invalidate_permissions) do |tenant_id: nil|
          calls << [id, tenant_id]
          super(tenant_id: tenant_id)
        end
        yield
        calls
      ensure
        User.send(:remove_method, :invalidate_permissions)
      end
    end
  end
end
