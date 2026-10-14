require 'test_helper'

module PermissionForge
  class ResourceFieldMaskValidationTest < ActiveSupport::TestCase
    setup do
      @permission_set = create_permission_set
      @resource = create_resource(permission_set: @permission_set, name: 'Customer')
    end

    # --- mask_access: true with valid strategies ---

    PermissionForge::Services::MaskValue::STRATEGIES.each do |strategy|
      test "mask_access true with strategy #{strategy} is valid" do
        field = build_field(read_access: true, mask_access: true, mask_strategy: strategy)
        assert field.valid?, "Expected field with strategy '#{strategy}' to be valid, errors: #{field.errors.full_messages}"
      end
    end

    # --- mask_access: true with invalid strategies ---

    test 'mask_access true with nil mask_strategy is invalid' do
      field = build_field(read_access: true, mask_access: true, mask_strategy: nil)
      assert_not field.valid?
      assert field.errors[:mask_strategy].any?
    end

    test 'mask_access true with unknown mask_strategy is invalid' do
      field = build_field(read_access: true, mask_access: true, mask_strategy: 'unknown')
      assert_not field.valid?
      assert field.errors[:mask_strategy].any?
    end

    test 'mask_access true with empty string mask_strategy is invalid' do
      field = build_field(read_access: true, mask_access: true, mask_strategy: '')
      assert_not field.valid?
      assert field.errors[:mask_strategy].any?
    end

    # --- mask_access: false (no validation on mask_strategy) ---

    test 'mask_access false with nil mask_strategy is valid' do
      field = build_field(read_access: true, mask_access: false, mask_strategy: nil)
      assert field.valid?, "Errors: #{field.errors.full_messages}"
    end

    test 'mask_access false with leftover email strategy is valid' do
      field = build_field(read_access: true, mask_access: false, mask_strategy: 'email')
      assert field.valid?, "Errors: #{field.errors.full_messages}"
    end

    test 'mask_access false with no mask_strategy is valid' do
      field = build_field(read_access: true, mask_access: false)
      assert field.valid?, "Errors: #{field.errors.full_messages}"
    end

    private

    def build_field(overrides = {})
      PermissionForge::ResourceField.new({
        uuid: SecureRandom.uuid,
        name: 'test_field',
        label: 'Test Field',
        resource: @resource,
        is_active: true,
        is_editable: true,
        read_access: true,
        edit_access: false,
        mask_access: false,
        mask_strategy: 'full'
      }.merge(overrides))
    end
  end
end
