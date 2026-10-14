require 'test_helper'

module PermissionForge
  class ConfigurationDriftTest < ActiveSupport::TestCase
    setup do
      @permission_set = create_permission_set
      @resource = create_resource(permission_set: @permission_set, name: 'Customer')
    end

    test 'after generation gdpr_patterns_changed_since_generation is false' do
      PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
      assert_not PermissionForge.configuration.gdpr_patterns_changed_since_generation?
    end

    test 'after changing patterns gdpr_patterns_changed_since_generation is true' do
      PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
      original = PermissionForge.configuration.gdpr_field_patterns

      PermissionForge.configuration.gdpr_field_patterns = { /custom_field/ => 'full' }
      assert PermissionForge.configuration.gdpr_patterns_changed_since_generation?
    ensure
      PermissionForge.configuration.gdpr_field_patterns = original
    end

    test 'after re-running generation gdpr_patterns_changed_since_generation is false again' do
      PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
      original = PermissionForge.configuration.gdpr_field_patterns

      PermissionForge.configuration.gdpr_field_patterns = { /custom_field/ => 'full' }
      assert PermissionForge.configuration.gdpr_patterns_changed_since_generation?

      # Reset patterns and re-run
      PermissionForge.configuration.gdpr_field_patterns = original
      # Create new resource to generate fields for (existing fields are skipped)
      new_resource = create_resource(permission_set: @permission_set, name: 'Supplier')
      PermissionForge::Services::ResourceFieldGenerator.call(resource: new_resource)
      assert_not PermissionForge.configuration.gdpr_patterns_changed_since_generation?
    ensure
      PermissionForge.configuration.gdpr_field_patterns = original
    end

    test 'before any generation gdpr_patterns_changed_since_generation is false' do
      # Fresh config — no checksum stored
      config = PermissionForge::Configuration.new
      assert_not config.gdpr_patterns_changed_since_generation?
    end
  end
end
