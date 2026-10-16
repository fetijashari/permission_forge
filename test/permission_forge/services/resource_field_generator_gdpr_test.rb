require 'test_helper'

module PermissionForge
  module Services
    class ResourceFieldGeneratorGdprTest < ActiveSupport::TestCase
      setup do
        @permission_set = create_permission_set
        @resource = create_resource(permission_set: @permission_set, name: 'Customer')
      end

      # Full access is what grant_all asks for: no mask, the recommended
      # strategy kept for when someone masks the field later.
      test 'grant_all true with gdpr_defaults true leaves the email field unmasked' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        email_field = fields.find { |f| f.name == 'email' }

        assert email_field.read_access
        assert email_field.edit_access
        assert_not email_field.mask_access, 'grant_all asks for full access: no mask'
        assert_equal 'email', email_field.mask_strategy
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'grant_all true with gdpr_defaults true does not mask non-PII fields' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        domain_field = fields.find { |f| f.name == 'domain' }

        assert domain_field.read_access
        assert domain_field.edit_access
        assert_not domain_field.mask_access
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'grant_all true with gdpr_defaults false does not mask email field' do
        PermissionForge.configuration.gdpr_defaults = false

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        email_field = fields.find { |f| f.name == 'email' }

        assert email_field.read_access
        assert email_field.edit_access
        assert_not email_field.mask_access
      end

      # A privacy default never grants: without grant_all the email field is
      # Hidden like every other column, its recommended strategy on the row
      # (through 0.14.1 it came back readable and masked — the only column
      # a "no access" generation opened).
      test 'grant_all false with gdpr_defaults true grants nothing: the email field is Hidden, its strategy recorded' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: false)
        email_field = fields.find { |f| f.name == 'email' }

        assert_not email_field.read_access
        assert_not email_field.edit_access
        assert_not email_field.mask_access
        assert_equal 'email', email_field.mask_strategy
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      # The one row builder, as the admin's presets, Sync and the Fields tab
      # call it: under gdpr_defaults a sensitive column granted Read-only
      # starts Masked; Hidden stays Hidden; Editable is full access.
      test 'build: the privacy default masks a sensitive column granted Read-only, and only that' do
        PermissionForge.configuration.gdpr_defaults = true
        levels = %w[hidden masked read edit].to_h do |level|
          row = ResourceFieldGenerator.build(resource: @resource, column: 'email', level: level)
          [level, PermissionForge::FieldLevel.level_of(PermissionForge::ResourceField.new(row), muting: false)]
        end

        assert_equal({ 'hidden' => 'hidden', 'masked' => 'masked', 'read' => 'masked', 'edit' => 'edit' }, levels)
        assert_equal 'read', PermissionForge::FieldLevel.level_of(
          PermissionForge::ResourceField.new(ResourceFieldGenerator.build(resource: @resource, column: 'domain', level: 'read')), muting: false
        )
        assert_nil ResourceFieldGenerator.build(resource: @resource, column: ' ', level: 'read')
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'build: a Muting Permission Set gets the level chosen, the privacy default adds nothing' do
        PermissionForge.configuration.gdpr_defaults = true
        muting = create_resource(permission_set: create_permission_set(name: 'Muting', is_muting: true), name: 'Customer')

        assert_nil ResourceFieldGenerator.build(resource: muting, column: 'email', level: 'leave'), 'Unchanged is no row'
        %w[mask hide].each do |level|
          row = ResourceFieldGenerator.build(resource: muting, column: 'email', level: level)
          assert_equal level, PermissionForge::FieldLevel.level_of(PermissionForge::ResourceField.new(row), muting: true)
          assert_equal 'email', row[:mask_strategy]
        end
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'grant_all true with gdpr_defaults true leaves the name field unmasked, first1_last4 recommended' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        name_field = fields.find { |f| f.name == 'name' }

        assert_not name_field.mask_access
        assert name_field.edit_access
        assert_equal 'first1_last4', name_field.mask_strategy
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'grant_all true with gdpr_defaults true: the auditor still reports the unmasked personal fields' do
        PermissionForge.configuration.gdpr_defaults = true

        ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        reported = GdprFieldAuditor.call.select { |f| f[:type] == :unmasked_field && f[:resource_name] == 'Customer' }

        assert_includes reported.map { |f| f[:field_name] }, 'email'
        assert_includes reported.map { |f| f[:field_name] }, 'name'
        assert_equal 'email', reported.find { |f| f[:field_name] == 'email' }[:suggested_strategy]
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'grant_all false with gdpr_defaults true leaves the name field Hidden, first1_last4 recommended' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: false)
        name_field = fields.find { |f| f.name == 'name' }

        assert_not name_field.read_access
        assert_not name_field.edit_access
        assert_not name_field.mask_access
        assert_equal 'first1_last4', name_field.mask_strategy
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end
    end
  end
end
