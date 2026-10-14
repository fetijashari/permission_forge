# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    class NilUserStrategyTest < ActiveSupport::TestCase
      setup do
        @customer = create_customer
        Current.user = nil
      end

      teardown do
        PermissionForge.configuration.nil_user_strategy = :bypass
      end

      test 'bypass strategy returns unscoped results when current_user is nil' do
        PermissionForge.configuration.nil_user_strategy = :bypass
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'bypass strategy logs a warning' do
        PermissionForge.configuration.nil_user_strategy = :bypass
        log_output = StringIO.new
        original_logger = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(log_output)

        Customer.find_by(uuid: @customer.uuid)
        assert_match(/current_user is nil.*bypassing/i, log_output.string)
      ensure
        Rails.logger = original_logger
      end

      test 'raise strategy raises NotAuthorizedError when current_user is nil' do
        PermissionForge.configuration.nil_user_strategy = :raise

        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: @customer.uuid)
        end
      end

      test 'deny strategy returns nil when current_user is nil' do
        PermissionForge.configuration.nil_user_strategy = :deny
        assert_nil Customer.find_by(uuid: @customer.uuid)
      end

      test 'with a valid current_user all strategies behave the same' do
        user = create_user
        ps = create_permission_set
        create_permission_set_user(user: user, permission_set: ps)
        create_resource(permission_set: ps, name: 'Customer', read_access: true)
        user.regenerate_permissions
        Current.user = user

        %i[bypass raise deny].each do |strategy|
          PermissionForge.configuration.nil_user_strategy = strategy
          assert_equal @customer, Customer.find_by(uuid: @customer.uuid),
                       "Failed for strategy #{strategy}"
        end
      end
    end
  end
end
