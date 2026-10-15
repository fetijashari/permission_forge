require 'test_helper'

module PermissionForge
  module Security
    # Pre-release review core-security #1: a field Masked in one Permission
    # Set and Hidden in another (read=f, mask=f, as the admin UI writes
    # Hidden) read as plaintext, because every row took part in the mask
    # AND. Only rows that grant read decide the mask and its strategy now,
    # whichever set is older, on every read path.
    class MaskedHiddenMergeTest < ActiveSupport::TestCase
      class GuardedCustomer < ::Customer
        include PermissionForge::Concerns::MaskedAttributes

        def self.name = 'Customer'
      end

      MASKED = { read_access: true, mask_access: true, mask_strategy: 'email' }.freeze
      MASKED_LAST4 = { read_access: true, mask_access: true, mask_strategy: 'last4' }.freeze
      HIDDEN = { read_access: false, mask_access: false }.freeze
      OPEN = { read_access: true, mask_access: false }.freeze

      setup do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        @user = create_user
        @customer = GuardedCustomer.create!(uuid: SecureRandom.uuid, name: 'Acme', email: 'secret@acme.com', domain: 'acme.com')
      end

      # The user's sets, created so that they merge in the given order.
      def grant_in_order(*field_rows)
        field_rows.each_with_index do |attrs, index|
          name = PermissionForge::PermissionSet.unique_name("Set #{index}")
          set = create_permission_set(name: name, created_at: Time.current - (field_rows.size - index).minutes)
          create_permission_set_user(user: @user, permission_set: set)
          resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
          create_resource_field(resource: resource, name: 'email', label: 'Email', **attrs)
        end
        @user.regenerate_permissions
        Current.user = @user
      end

      def email_through_every_path
        [@customer.email,
         GuardedCustomer.find(@customer.id).as_json['email'],
         PermissionForge::Services::FiltersResponseAttributes.call(
           attributes: { email: 'secret@acme.com' }, resource_name: 'Customer', user: @user
         )[:email]]
      end

      test 'masked in one set and hidden in another is masked, whichever set is older' do
        [[MASKED, HIDDEN], [HIDDEN, MASKED]].each do |order|
          @user = create_user
          grant_in_order(*order)

          entry = @user.field_permissions(:Customer, :email)
          assert_equal [true, true, 'email'], entry.values_at(:read_access, :mask_access, :mask_strategy), order.inspect
          assert_equal ['s***@acme.com'] * 3, email_through_every_path, order.inspect
        end
      end

      test 'two masked sets and a hidden one: masked, with the strategy of the first masked set' do
        [MASKED, MASKED_LAST4, HIDDEN].permutation.each do |order|
          @user = create_user
          grant_in_order(*order)
          strategy = order.find { |attrs| attrs[:mask_access] }[:mask_strategy]
          masked = PermissionForge::Services::MaskValue.call('secret@acme.com', strategy: strategy)

          entry = @user.field_permissions(:Customer, :email)
          assert_equal [true, true, strategy], entry.values_at(:read_access, :mask_access, :mask_strategy), order.inspect
          assert_equal [masked] * 3, email_through_every_path, order.inspect
        end
      end

      test 'unmasked in one set and hidden in another is readable in full, as before' do
        [[OPEN, HIDDEN], [HIDDEN, OPEN]].each do |order|
          @user = create_user
          grant_in_order(*order)

          assert_equal [true, false], @user.field_permissions(:Customer, :email).values_at(:read_access, :mask_access)
          assert_equal ['secret@acme.com'] * 3, email_through_every_path, order.inspect
        end
      end

      test 'hidden in every set stays hidden' do
        grant_in_order(HIDDEN, HIDDEN)

        assert_equal false, @user.field_permissions(:Customer, :email)[:read_access]
        assert_nil @customer.email
        assert_not GuardedCustomer.find(@customer.id).as_json.key?('email')
        assert_empty PermissionForge::Services::FiltersResponseAttributes.call(
          attributes: { email: 'secret@acme.com' }, resource_name: 'Customer', user: @user
        )
      end

      test 'the admin read model explains the field the way the engine enforces it' do
        [[MASKED, HIDDEN], [HIDDEN, MASKED], [MASKED_LAST4, HIDDEN, MASKED]].each do |order|
          @user = create_user
          grant_in_order(*order)
          shown = PermissionForge::Admin::EffectiveAccess.call(user: @user).find { |r| r.name == 'Customer' }
                                                         .fields.find { |f| f.name == 'email' }

          assert_equal 'masked', shown.level, order.inspect
          assert_equal @user.field_permissions(:Customer, :email)[:mask_strategy], shown.mask_strategy, order.inspect
        end
      end
    end
  end
end
