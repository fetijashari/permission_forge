# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Services
    # A field row whose mask strategy this app does not know (written past
    # the model, or a custom strategy since removed from the configuration)
    # is masked fully at read time; `rake permission_forge:audit` names the
    # row so it gets fixed. And "this name is a model" has one definition
    # (ModelLookup): a Resource named `Kernel` is a Resource for a model
    # this app does not have.
    class SecurityAuditIntegrityCheckTest < ActiveSupport::TestCase
      setup do
        @config = PermissionForge::Configuration.new
        @config.user_class = 'User'
        @set = create_permission_set(name: 'Sales')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
      end

      def audit
        SecurityAudit.call(configuration: @config, environment: 'test')
      end

      def finding(code) = audit.findings.find { |item| item.code == code }

      test 'a field in effect with a mask strategy this app does not know is reported, high while people hold the set' do
        email = create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        email.update_columns(mask_strategy: 'gone')
        blank = create_resource_field(resource: @resource, name: 'name', read_access: true, mask_access: true, mask_strategy: 'full')
        blank.update_columns(mask_strategy: '')

        found = finding(:unknown_mask_strategies)

        assert_equal :medium, found.severity
        assert_equal 'integrity', found.check
        assert_match 'masked fully', found.detail
        assert_equal ['Sales › Customer.email: "gone" · 0 people', 'Sales › Customer.name: "" · 0 people'], found.items

        create_permission_set_user(user: create_user, permission_set: @set)

        assert_equal :high, finding(:unknown_mask_strategies).severity
      end

      test 'a custom strategy that was removed from the configuration is reported; one that is configured is not' do
        PermissionForge.configuration.custom_mask_strategies = { 'initials' => ->(value) { value[0] } }
        create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: true, mask_strategy: 'initials')

        assert_nil finding(:unknown_mask_strategies)

        PermissionForge.configuration.custom_mask_strategies = {}

        assert_equal ['Sales › Customer.email: "initials" · 0 people'], finding(:unknown_mask_strategies).items
      end

      test 'a row that is not in effect, or does not mask, is not reported' do
        off = create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: true,
                                    mask_strategy: 'email', is_active: false)
        off.update_columns(mask_strategy: 'gone')
        unmasked = create_resource_field(resource: @resource, name: 'name', read_access: true, mask_access: false)
        unmasked.update_columns(mask_strategy: 'gone')
        parked = create_resource(permission_set: create_permission_set(name: 'Parked', is_active: false), read_access: true)
        parked_email = create_resource_field(resource: parked, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        parked_email.update_columns(mask_strategy: 'gone')

        assert_nil finding(:unknown_mask_strategies)
      end

      test 'a Resource named after a constant that is no model with a table is a Resource for a model this app does not have' do
        %w[Kernel String PermissionForge Custmer].each { |name| create_resource(permission_set: @set, name: name) }

        assert_equal %w[Custmer Kernel PermissionForge String], finding(:unknown_models).items
      end
    end
  end
end
