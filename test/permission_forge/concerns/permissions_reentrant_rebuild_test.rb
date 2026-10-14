require 'test_helper'

module PermissionForge
  module Concerns
    # Building a hash can ask for the permissions of the user it is built for:
    # the profile builder reads attributes, and on a masked User model each
    # getter asks the current user. That call is answered with {} — which must
    # never be what an instance goes on to use.
    class PermissionsReentrantRebuildTest < ActiveSupport::TestCase
      setup do
        @set = create_permission_set
        resource = create_resource(permission_set: @set)
        create_permission_set_rule(permission_set: @set, resource: resource, field_name: 'name', field_value: 'Allowed',
                                   operator: 'equal', include_nulls: false)
        create_customer(name: 'Allowed')
        create_customer(name: 'Denied')
        @user = create_user
        create_permission_set_user(user: @user, permission_set: @set)

        # What a masked attribute reader does while the profile is built.
        @profile_builder = PermissionForge.configuration.profile_builder
        builder = @profile_builder
        PermissionForge.configuration.profile_builder = lambda do |user|
          PermissionForge.current_user&.permissions_hash
          builder.call(user)
        end
        PermissionForge.cache.clear
      end

      teardown do
        PermissionForge.configuration.profile_builder = @profile_builder
        Current.reset
      end

      [true, false].each do |snapshot|
        test "another instance of the user is not left with an empty hash (snapshot_transactions: #{snapshot})" do
          PermissionForge.configuration.snapshot_transactions = snapshot
          Current.user = ::User.find(@user.id)
          found = ::User.find(@user.id)

          ActiveRecord::Base.transaction do
            assert found.can_read?(:Customer)

            assert_not_equal({}, Current.user.permissions_hash)
            assert Current.user.can_read?(:Customer)
            assert_equal ['Allowed'], ::Customer.permission_scoped.pluck(:name)
          end
        end
      end

      test 'the instance that builds, asked again by its own build, keeps what it built' do
        PermissionForge.configuration.snapshot_transactions = true
        Current.user = ::User.find(@user.id)

        ActiveRecord::Base.transaction do
          assert Current.user.can_read?(:Customer)
          assert_not_equal({}, Current.user.permissions_hash)
        end
      end

      test 'two instances inside one transaction settle after a bounded number of builds' do
        PermissionForge.configuration.snapshot_transactions = true
        Current.user = ::User.find(@user.id)
        found = ::User.find(@user.id)
        builds = 0
        counting = PermissionForge.configuration.profile_builder
        PermissionForge.configuration.profile_builder = lambda do |user|
          builds += 1
          counting.call(user)
        end

        ActiveRecord::Base.transaction do
          5.times { [found, Current.user].each { |person| assert person.can_read?(:Customer) } }
        end

        assert_operator builds, :<=, 3, 'the instances must not rebuild in turns'
      end
    end
  end
end
