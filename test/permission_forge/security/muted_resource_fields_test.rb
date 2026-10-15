require 'test_helper'

module PermissionForge
  module Security
    # Pre-release review core-security #5: a Muting Permission Set that
    # revoked a resource's read left every field of that resource readable
    # (and one that revoked its edit left every field editable), because
    # field enforcement never consults the resource flags. Muting a resource
    # must protect at least as much as never granting it.
    class MutedResourceFieldsTest < ActiveSupport::TestCase
      class GuardedCustomer < ::Customer
        include PermissionForge::Concerns::MaskedAttributes

        def self.name = 'Customer'
      end

      setup do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        @user = create_user
        granting = create_permission_set(name: 'CRM')
        create_permission_set_user(user: @user, permission_set: granting)
        resource = create_resource(permission_set: granting, name: 'Customer', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'name', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'email', label: 'Email', read_access: true, mask_access: true,
                              mask_strategy: 'email')
        create_resource_field(resource: resource, name: 'supplier_id', label: 'Supplier', read_access: true, edit_access: true)
        @customer = GuardedCustomer.create!(uuid: SecureRandom.uuid, name: 'Acme', email: 'secret@acme.com', domain: 'acme.com',
                                            supplier_id: 7)
      end

      # A muting set whose Customer resource revokes the given flags.
      def mute(**flags)
        muting = create_permission_set(name: 'Offboarding', is_muting: true)
        create_permission_set_user(user: @user, permission_set: muting)
        create_resource(permission_set: muting, name: 'Customer', read_access: false, **flags)
        @user.regenerate_permissions
        Current.user = @user
        muting
      end

      def filtered
        PermissionForge::Services::FiltersResponseAttributes.call(
          attributes: { name: 'Acme', email: 'secret@acme.com', supplier_id: 7, supplier_uuid: 'u', full_address: 'x' },
          resource_name: 'Customer', user: @user
        )
      end

      def permitted
        PermissionForge::Services::PermitsAttributes.call(
          resource: ::Customer, permitted_params: { 'name' => 'x', 'supplier_id' => 1, 'full_address' => 'y' }
        )
      end

      test 'muting the resource read hides every field, variants and implicit virtual fields included' do
        mute(read_access: true)

        assert_not @user.can_read?(:Customer)
        fields = @user.permissions_hash_for(:Customer)[:fields]
        # Customer has no supplier_uuid: no variant entry, but filtered's
        # supplier_uuid key follows supplier_id (FieldVariants.base_entries)
        assert_equal %i[email full_address contact_count name supplier_id].sort, fields.keys.sort
        fields.each do |name, entry|
          assert_equal [false, false], entry.values_at(:read_access, :edit_access), name
        end

        assert_nil @customer.name
        assert_nil @customer.email
        assert_equal({ 'id' => @customer.id }, GuardedCustomer.find(@customer.id).as_json.slice('id', 'name', 'email', 'supplier_id'))
        assert_empty filtered
        assert_empty permitted
      end

      # A muting set that revokes only the resource's edit ("can submit, cannot
      # change afterwards") leaves the field rows alone: PermitsAttributes
      # filters creates too, so a cascade there blocked creation (review MAJOR-2).
      test 'muting the resource edit leaves the fields to their rows, so a create still goes through' do
        mute(edit_access: true)

        assert @user.can_read?(:Customer)
        assert_not @user.can_edit?(:Customer)
        fields = @user.permissions_hash_for(:Customer)[:fields]
        assert_equal [true, true], fields[:name].values_at(:read_access, :edit_access)
        assert_equal [true, true], fields[:full_address].values_at(:read_access, :edit_access), 'the implicit entry follows the granting merge'

        assert_equal 'Acme', @customer.name
        assert_equal 's***@acme.com', @customer.email
        assert_equal({ name: 'Acme', email: 's***@acme.com', supplier_id: 7, supplier_uuid: 'u', full_address: 'x' }, filtered)
        assert_equal({ 'name' => 'x', 'supplier_id' => 1, 'full_address' => 'y' }, permitted)
      end

      test 'a muting set that revokes neither read nor edit leaves the fields to its own field rows' do
        mute(delete_access: true)

        assert_equal 'Acme', @customer.name
        assert_equal({ 'name' => 'x', 'supplier_id' => 1, 'full_address' => 'y' }, permitted)
      end

      test 'muting applies to the fields granted by every granting set, not only the first' do
        later = create_permission_set(name: 'Later')
        create_permission_set_user(user: @user, permission_set: later)
        resource = create_resource(permission_set: later, name: 'Customer', read_access: true)
        create_resource_field(resource: resource, name: 'domain', label: 'Domain', read_access: true)
        mute(read_access: true)

        assert_equal false, @user.field_permissions(:Customer, :domain)[:read_access]
        assert_nil GuardedCustomer.find(@customer.id).domain
      end

      test 'the admin read model hides the fields the engine hides, naming the muting set' do
        muting = mute(read_access: true)
        shown = PermissionForge::Admin::EffectiveAccess.call(user: @user).find { |r| r.name == 'Customer' }

        assert_predicate shown.op(:read_access), :blocked?
        configured = shown.fields.reject(&:unconfigured)
        assert_not_empty configured
        configured.each do |field|
          assert_equal 'hidden', field.level, field.name
          assert_includes field.blocked_by, muting, field.name
        end
      end
    end
  end
end
