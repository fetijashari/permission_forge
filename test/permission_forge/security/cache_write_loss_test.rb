require 'test_helper'

module PermissionForge
  module Security
    # A cache store that does not keep what was written — the :null backend, a
    # NullStore behind Rails.cache (the stock Rails test environment), a store
    # outage — must never turn into "this user has no permissions". An empty
    # hash denies every can_*? check but also empties permission_set_rules,
    # which silently switches row-level rules off.
    class CacheWriteLossTest < ActiveSupport::TestCase
      NotAuthorizedError = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

      # Reads miss and writes are dropped, as with an unreachable Redis:
      # ActiveSupport cache stores rescue the error and return nil / false.
      class UnreachableStore < ActiveSupport::Cache::MemoryStore
        def read(*)
          nil
        end

        # rubocop:disable-next Naming/PredicateMethod -- overrides ActiveSupport::Cache::Store#write
        def write(*)
          false
        end
      end

      STORES = {
        'the :null backend' => -> { :null },
        'a NullStore behind the rails-cache wrapper' => -> { ActiveSupport::Cache::NullStore.new },
        'a store that drops writes' => -> { UnreachableStore.new }
      }.freeze

      setup do
        @user = create_user
        @set = create_permission_set
        @assignment = create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_resource_field(resource: @resource, name: 'name', read_access: true)
        create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: true,
                              mask_strategy: 'email')
        create_permission_set_rule(permission_set: @set, resource: @resource, field_name: 'supplier_id',
                                   field_value: 'current_user', operator: 'equal', include_nulls: false)
        @mine = create_customer(name: 'Mine', supplier_id: @user.id)
        @theirs = create_customer(name: 'Theirs', supplier_id: @user.id + 1)
        @profile_builder = PermissionForge.configuration.profile_builder
        Current.user = @user
      end

      teardown do
        use_store(:memory)
        PermissionForge.configuration.auto_query_scoping = :off
        PermissionForge.configuration.profile_builder = @profile_builder
      end

      STORES.each do |label, store|
        test "#{label}: resource access is still granted" do
          use_store(store.call)

          assert @user.can_read?(:Customer)
          assert_not @user.can_delete?(:Customer)
        end

        test "#{label}: the row-level rule is in the hash and find_by enforces it" do
          use_store(store.call)

          assert_equal 1, Array(@user.permissions_hash.dig(:permissions, :resources, :Customer, :permission_set_rules)).size
          assert_equal @mine.id, Customer.find_by(id: @mine.id)&.id
          assert_raises(NotAuthorizedError) { Customer.find_by(id: @theirs.id) }
        end

        test "#{label}: permission_scoped and auto query scoping filter rows" do
          use_store(store.call)

          assert_equal [@mine.id], Customer.permission_scoped.pluck(:id)

          PermissionForge.configuration.auto_query_scoping = :filter_only
          assert_equal [@mine.id], Customer.all.pluck(:id)
        end

        test "#{label}: field grants and masks are intact" do
          use_store(store.call)

          assert @user.field_permissions(:Customer, :name)&.dig(:read_access)
          assert @user.masked_field?(:Customer, :email)
        end

        test "#{label}: a revocation takes effect" do
          use_store(store.call)
          assert @user.can_read?(:Customer)

          @assignment.destroy!

          assert_not @user.can_read?(:Customer)
        end
      end

      test 'a re-entrant read during the rebuild is still an empty placeholder' do
        use_store(:null)
        inner = :not_called
        PermissionForge.configuration.profile_builder = lambda { |user|
          inner = user.permissions_hash
          { id: user.id }
        }

        assert @user.can_read?(:Customer)
        assert_equal({}, inner)
      end

      private

      def use_store(backend)
        PermissionForge.configuration.cache_backend = backend
        PermissionForge.configuration.reset_cache_store!
      end
    end
  end
end
