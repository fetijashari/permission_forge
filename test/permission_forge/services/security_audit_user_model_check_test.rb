# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Services
    # SecurityAuditChecks::UserModelCheck — what the user model costs sign-in
    # and what it shows with nobody signed in. Customer stands in for the
    # user model (it includes PermissionScopedFindable; never a Resource row
    # named User in the suite).
    class SecurityAuditUserModelCheckTest < ActiveSupport::TestCase
      setup do
        @config = PermissionForge::Configuration.new
        @config.user_class = 'Customer'
      end

      def findings(**overrides)
        overrides.each { |key, value| @config.public_send("#{key}=", value) }
        SecurityAuditChecks::UserModelCheck.new(configuration: @config, environment: 'test').call
      end

      def finding(code, **) = findings(**).find { |item| item.code == code }

      test 'is part of the audit and quiet on the library defaults' do
        assert_includes SecurityAudit.checks, SecurityAuditChecks::UserModelCheck
        @config.user_class = 'User'
        assert_empty findings
      end

      test 'a user model with record rules under :deny or :raise cannot be looked up before sign-in' do
        %i[deny raise].each do |strategy|
          found = finding(:user_model_scoped, nil_user_strategy: strategy)

          assert_equal :low, found.severity, strategy
          assert_equal 'user_model', found.check
          assert_match 'PermissionScopedFindable', found.detail
          assert_match 'sign-in', found.detail
        end
        assert_nil finding(:user_model_scoped, nil_user_strategy: :bypass)
        assert_nil finding(:user_model_scoped, nil_user_strategy: :deny, user_class: 'User'), 'User does not include it'
      end

      test 'under :hide a user model with a Resource row reads as stored with nobody signed in' do
        assert_nil finding(:user_model_unmasked_without_user, masked_attributes_nil_user_strategy: :hide), 'no Resource row'

        create_resource(permission_set: create_permission_set(name: 'Staff'), name: 'Customer')
        found = finding(:user_model_unmasked_without_user, masked_attributes_nil_user_strategy: :hide)

        assert_equal :low, found.severity
        assert_match 'password', found.detail
        assert_equal ['Customer'], found.items
        assert_nil finding(:user_model_unmasked_without_user, masked_attributes_nil_user_strategy: :bypass)
      end

      test 'a user_class that names no class reports nothing' do
        assert_empty findings(user_class: 'NoSuchUserModel', nil_user_strategy: :deny, masked_attributes_nil_user_strategy: :hide)
      end
    end
  end
end
