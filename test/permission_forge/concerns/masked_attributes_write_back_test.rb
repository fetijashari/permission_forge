require 'test_helper'

module PermissionForge
  module Concerns
    # Regression tests for the masked write-back guard: a callback that reads a
    # masked value and writes it back must not corrupt the stored column.
    class MaskedAttributesWriteBackTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(permission_set: @permission_set, name: 'Customer', read_access: true)
        create_resource_field(
          resource: @resource, name: 'email', label: 'Email',
          read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email'
        )
        create_resource_field(
          resource: @resource, name: 'name', label: 'Name',
          read_access: false, edit_access: false
        )
        @user.regenerate_permissions
        Current.user = @user
        @customer = create_customer(email: 'secret@example.com', name: 'Jane Doe')
      end

      test 'reading returns the masked value' do
        assert_equal 's***@example.com', @customer.email
      end

      test 'writing the masked value back is skipped, preserving the raw column (:skip)' do
        PermissionForge.configuration.masked_write_protection = :skip
        # Simulate `before_save { self.email = email.strip }`
        masked = @customer.email
        @customer.email = masked.strip
        @customer.save!

        raw = @customer.read_attribute_before_type_cast(:email)
        assert_equal 'secret@example.com', raw, 'stored email must not be overwritten with the mask'
      end

      test 'writing back a hidden (nil) value is skipped, preserving the raw column' do
        PermissionForge.configuration.masked_write_protection = :skip
        hidden = @customer.name # hidden (no read access)
        assert_nil hidden
        @customer.name = hidden # write the hidden sentinel back
        @customer.save!

        assert_equal 'Jane Doe', @customer.read_attribute_before_type_cast(:name)
      end

      test 'writing a genuinely new value still works' do
        @customer.email = 'new@example.com'
        @customer.save!
        assert_equal 'new@example.com', @customer.read_attribute_before_type_cast(:email)
      end

      test ':raise mode raises MaskedWriteError on write-back' do
        PermissionForge.configuration.masked_write_protection = :raise
        masked = @customer.email
        assert_raises(PermissionForge::Concerns::MaskedAttributes::MaskedWriteError) do
          @customer.email = masked
        end
      end

      test ':off mode restores legacy behavior (mask gets persisted)' do
        PermissionForge.configuration.masked_write_protection = :off
        masked = @customer.email
        @customer.email = masked
        @customer.save!
        assert_equal 's***@example.com', @customer.read_attribute_before_type_cast(:email)
      end

      # The per-instance ledger cannot protect the classic form roundtrip: request 1
      # renders "s***@example.com", request 2 loads a FRESH record and submits it
      # back. The stateless guard (compare against the persisted value's mask) must
      # still refuse the write.
      test 'writing the masked value back on a freshly-loaded instance is skipped (cross-request)' do
        PermissionForge.configuration.masked_write_protection = :skip
        masked = ::Customer.find(@customer.id).email # request 1
        assert_equal 's***@example.com', masked

        fresh = ::Customer.find(@customer.id) # request 2 — no ledger entry
        fresh.email = masked
        fresh.save!

        assert_equal 'secret@example.com', fresh.read_attribute_before_type_cast(:email),
                     'cross-request masked write-back must not overwrite the stored value'
      end

      test 'writing back the hidden sentinel on a freshly-loaded instance is skipped (cross-request)' do
        PermissionForge.configuration.masked_write_protection = :skip
        fresh = ::Customer.find(@customer.id)
        fresh.name = PermissionForge.configuration.hidden_attribute_value # nil sentinel
        fresh.save!

        assert_equal 'Jane Doe', fresh.read_attribute_before_type_cast(:name)
      end

      test 'a genuinely new value on a freshly-loaded instance still writes' do
        PermissionForge.configuration.masked_write_protection = :skip
        fresh = ::Customer.find(@customer.id)
        fresh.email = 'brand-new@example.com'
        fresh.save!

        assert_equal 'brand-new@example.com', fresh.read_attribute_before_type_cast(:email)
      end
    end
  end
end
