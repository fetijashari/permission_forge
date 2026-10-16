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

    # --- check on change: a row written past the model, or whose custom
    # strategy was removed from the configuration, stays editable ---

    test 'a saved row with a strategy this app does not know stays editable in its other attributes' do
      field = build_field(read_access: true, mask_access: true, mask_strategy: 'email')
      field.save!
      field.update_columns(mask_strategy: 'gone')
      field.reload
      field.label = 'Renamed'

      assert field.valid?, field.errors.full_messages.inspect
      assert field.save
    end

    test 'the strategy is checked again when it, or mask_access, changes' do
      field = build_field(read_access: true, mask_access: false, mask_strategy: 'full')
      field.save!
      field.update_columns(mask_strategy: 'gone')
      field.reload
      field.mask_access = true

      assert_not field.valid?
      assert field.errors[:mask_strategy].any?, 'mask_access switched on with an unknown strategy'

      field.reload
      field.mask_access = true
      field.mask_strategy = 'still_gone'

      assert_not field.valid?

      field.mask_strategy = 'email'

      assert field.valid?, field.errors.full_messages.inspect
    end

    test 'a custom strategy removed from the configuration leaves the row editable, and is refused when picked again' do
      PermissionForge.configuration.custom_mask_strategies = { 'initials' => ->(value) { value[0] } }
      field = build_field(read_access: true, mask_access: true, mask_strategy: 'initials')
      field.save!
      PermissionForge.configuration.custom_mask_strategies = {}
      field.reload

      assert field.valid?, field.errors.full_messages.inspect

      other = build_field(name: 'other', read_access: true, mask_access: true, mask_strategy: 'initials')

      assert_not other.valid?
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
