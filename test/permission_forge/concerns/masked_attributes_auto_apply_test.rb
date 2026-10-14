require 'test_helper'

module PermissionForge
  module Concerns
    class MaskedAttributesAutoApplyTest < ActiveSupport::TestCase
      # NOTE: We deliberately use ::Supplier here (not Customer) because Customer
      # is constantly under permission setup in other tests; Supplier gives us a
      # clean class whose include-state we can assert against without flake.

      teardown do
        # The concern is irreversibly mixed into the class on auto-apply. We can't
        # un-include, so subsequent tests must tolerate Supplier having the concern.
        # That's fine — the concern is a no-op without field permissions configured.
      end

      test 'engine auto-applies MaskedAttributes when a Resource exists for the model' do
        permission_set = create_permission_set
        ::PermissionForge::Resource.create!(
          uuid: SecureRandom.uuid, permission_set: permission_set, name: 'Supplier',
          read_access: true, is_active: true, is_editable: true
        )

        # The Resource.after_create_commit hook should have applied the concern.
        assert PermissionForge::Concerns::MaskedAttributes.applied?(::Supplier),
               'Expected Supplier to have MaskedAttributes auto-applied after Resource creation'
      end

      test 'engine method is idempotent — repeated calls do not double-prepend' do
        permission_set = create_permission_set
        ::PermissionForge::Resource.find_or_create_by!(name: 'Supplier', permission_set: permission_set) do |r|
          r.uuid = SecureRandom.uuid
          r.read_access = true
          r.is_active = true
          r.is_editable = true
        end

        # Capture method count before, then re-apply, then compare
        readers_before = ::Supplier.ancestors.count { |a| a.name.to_s.include?('MaskedAttributeReaders') }
        PermissionForge::MaskedModels.apply
        PermissionForge::MaskedModels.apply
        readers_after = ::Supplier.ancestors.count { |a| a.name.to_s.include?('MaskedAttributeReaders') }

        assert_equal readers_before, readers_after,
                     'MaskedAttributeReaders module should appear only once in the ancestor chain'
      end

      test 'engine apply skips models without a Resource record' do
        # Build the candidate list directly from current Resource state — test
        # without mutating any host class. Once a class is included with the
        # concern, it can't be undone, so we test the engine's *decision*, not
        # the post-include state.
        names = PermissionForge::MaskedModels.send(:resource_names)
        refute_includes names, 'NonExistentTestModel'
      end

      test 'auto-apply respects auto_apply_masked_attributes = false' do
        PermissionForge.configuration.auto_apply_masked_attributes = false

        # Engine method must early-return without including the concern.
        before_applied = PermissionForge::Concerns::MaskedAttributes.applied?(::Account)
        PermissionForge::MaskedModels.apply(only: 'Account')
        after_applied = PermissionForge::Concerns::MaskedAttributes.applied?(::Account)

        assert_equal before_applied, after_applied
      ensure
        PermissionForge.configuration.auto_apply_masked_attributes = :auto
      end

      test 'auto-applied class enforces field permissions on direct getters' do
        user = create_user
        permission_set = create_permission_set
        create_permission_set_user(user: user, permission_set: permission_set)
        resource = ::PermissionForge::Resource.find_or_create_by!(name: 'Supplier', permission_set: permission_set) do |r|
          r.uuid = SecureRandom.uuid
          r.read_access = true
          r.is_active = true
          r.is_editable = true
        end
        ::PermissionForge::ResourceField.find_or_create_by!(resource: resource, name: 'name') do |f|
          f.uuid = SecureRandom.uuid
          f.label = 'Name'
          f.read_access = true
          f.mask_access = true
          f.mask_strategy = 'full'
          f.is_active = true
          f.is_editable = true
        end
        user.regenerate_permissions
        Current.user = user

        supplier = create_supplier(name: 'Acme Industrial')
        assert_equal '*' * 8, supplier.name,
                     'Supplier#name should be masked since the gem auto-applied MaskedAttributes'
      end

      test 'allowlist mode rejects names not in the list' do
        # Restrict to Supplier — calling apply with Account-like name must be a no-op.
        PermissionForge.configuration.auto_apply_masked_attributes = ['Supplier']
        candidates = PermissionForge::MaskedModels.send(:model_names, PermissionForge.configuration.auto_apply_masked_attributes,
                                                        only: 'Account')
        assert_empty candidates, 'Allowlist should reject Account when only :Supplier is listed'
      ensure
        PermissionForge.configuration.auto_apply_masked_attributes = :auto
      end

      test 'safe_constantize returns nil for unknown model names without raising' do
        permission_set = create_permission_set
        # Create a Resource for a class that does not exist
        ::PermissionForge::Resource.create!(
          uuid: SecureRandom.uuid, permission_set: permission_set, name: 'NonExistentModel',
          read_access: true, is_active: true, is_editable: true
        )

        # Engine should not raise
        assert_nothing_raised do
          PermissionForge::MaskedModels.apply
        end
      end
    end
  end
end
