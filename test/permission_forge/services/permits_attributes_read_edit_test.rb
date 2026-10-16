# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Services
    # D.4 (plan-final.md §2 SD): a key is editable only where the field is
    # readable AND editable. The hash the builder writes says so already
    # (FieldPermissionMerger counts edit only with read); a hash another
    # version cached, or one a host built by hand, may still say
    # `edit_access: true, read_access: false` — the filter must not keep
    # that key either.
    class PermitsAttributesReadEditTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @customer = create_customer
        Current.user = @user
      end

      def user_with_fields(fields)
        hash = { profile: {}, preferences: {},
                 permissions: { resources: { Customer: { permissions: { read_access: true, edit_access: true },
                                                         fields: fields, actions: {}, source_permission_sets: [],
                                                         permission_set_rules: [] } } } }
        replace_singleton_method(@user, :permissions_hash) { hash }
        @user
      end

      test 'a field entry with edit but no read is not editable' do
        user_with_fields(name: { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' },
                         email: { read_access: false, edit_access: true, mask_access: false, mask_strategy: 'full' })

        kept = PermitsAttributes.call(resource: @customer, permitted_params: { name: 'n', email: 'e' })

        assert_equal({ 'name' => 'n' }, kept)
      end
    end
  end
end
