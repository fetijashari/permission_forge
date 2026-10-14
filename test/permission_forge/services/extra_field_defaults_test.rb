require 'test_helper'
require_relative '../virtual_field_models'

module PermissionForge
  module Services
    # The implicit grant for declared extra (virtual) fields and
    # config.extra_fields_default_access. Collisions with configured fields and
    # set order are covered in test/permission_forge/security/hardening_test.rb.
    class ExtraFieldDefaultsTest < ActiveSupport::TestCase
      IMPLICIT = { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' }.freeze
      READ_ONLY = { read_access: true, edit_access: false, mask_access: false, mask_strategy: 'full' }.freeze
      # The merged permissions of a resource with read and edit (the setup's).
      READ_EDIT = { read_access: true, edit_access: true }.freeze

      setup do
        @config = PermissionForge.configuration
        @user = create_user
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true, edit_access: true)
        create_resource_field(resource: @resource, name: 'name', read_access: true)
      end

      # The fields the engine builds for one resource of @set: String keys, as
      # PermissionHashBuilder leaves them before the cache symbolizes the hash.
      def built_fields(resource_name = 'Customer')
        PermissionHashBuilder.call(user: @user, permission_sets: [@set])[:resources][resource_name][:fields]
      end

      # --- through PermissionHashBuilder ----------------------------------------

      test 'under :grant a declared virtual field with no row is readable and editable' do
        fields = built_fields

        assert_equal IMPLICIT, fields['full_address']
        assert_equal IMPLICIT, fields['contact_count']
        assert_equal %w[contact_count full_address name], fields.keys.sort
      end

      test 'under :unconfigured a declared virtual field gets no entry' do
        @config.extra_fields_default_access = :unconfigured

        assert_equal %w[name], built_fields.keys
      end

      test ':unconfigured (Symbol or String) gives no implicit entry; other values are refused' do
        [:unconfigured, 'unconfigured'].each do |value|
          @config.extra_fields_default_access = value
          assert_equal %w[name], built_fields.keys, "value #{value.inspect}"
        end
        [:typo, nil, false].each do |value|
          assert_raises(PermissionForge::ConfigurationError) { @config.extra_fields_default_access = value }
        end

        @config.extra_fields_default_access = 'grant'
        assert_includes built_fields.keys, 'full_address'
      end

      test 'a configured virtual field keeps its row in both modes' do
        create_resource_field(resource: @resource, name: 'full_address', read_access: true, mask_access: true)

        %i[grant unconfigured].each do |mode|
          @config.extra_fields_default_access = mode
          entry = built_fields['full_address']
          assert_equal [true, false, true], entry.values_at(:read_access, :edit_access, :mask_access), "mode #{mode}"
        end
      end

      # The engine skips a switched-off row, so the field is treated as one
      # nobody configured.
      test 'a switched-off row is no row: the field is back on the implicit grant' do
        create_resource_field(resource: @resource, name: 'full_address', read_access: false, is_active: false)

        assert_equal IMPLICIT, built_fields['full_address']

        @config.extra_fields_default_access = :unconfigured
        assert_not built_fields.key?('full_address')
      end

      test 'a discovered name never gets the implicit entry, in either mode' do
        @config.virtual_field_discovery = true
        create_resource(permission_set: @set, name: 'PfVirtualAccount', read_access: true)

        @config.extra_fields_default_access = :grant
        assert_equal %w[full_address], built_fields('PfVirtualAccount').keys

        @config.extra_fields_default_access = :unconfigured
        assert_empty built_fields('PfVirtualAccount')
      end

      test 'a model whose extra-fields method raises fails the build instead of changing permissions' do
        create_resource(permission_set: @set, name: 'PfVirtualBrokenProfile', read_access: true)

        error = assert_raises(ArgumentError) { built_fields('PfVirtualBrokenProfile') }
        assert_equal 'extra fields are broken', error.message

        @config.extra_fields_default_access = :unconfigured
        assert_empty built_fields('PfVirtualBrokenProfile'), 'the method is not read when nothing is granted by default'
      end

      # --- the implicit grant follows the resource's own flags ---------------------

      # A declared virtual field used to be editable for everyone who could
      # read the resource, so a read-only user's PermitsAttributes kept it
      # (pre-release review core-security #9).
      test 'the implicit entry grants edit only when the resource grants edit' do
        @resource.update!(edit_access: false)

        assert_equal READ_ONLY, built_fields['full_address']
        assert_equal READ_ONLY, built_fields['contact_count']
      end

      test 'the implicit entry grants read only when the resource grants read' do
        @resource.update!(read_access: false, edit_access: false)

        assert_equal READ_ONLY.merge(read_access: false), built_fields['full_address']
      end

      test 'edit granted by any granting set is enough, as for a column' do
        @resource.update!(edit_access: false)
        other = create_permission_set
        create_permission_set_user(user: @user, permission_set: other)
        create_resource(permission_set: other, name: 'Customer', read_access: true, edit_access: true)
        @user.regenerate_permissions

        assert_equal IMPLICIT, @user.field_permissions(:Customer, :full_address)
      end

      test 'a read-only user cannot write a declared virtual field' do
        @resource.update!(edit_access: false)
        @user.regenerate_permissions
        Current.user = @user

        assert_not @user.can_edit?(:Customer)
        assert_empty PermitsAttributes.call(resource: ::Customer,
                                            permitted_params: { 'name' => 'x', 'full_address' => 'y', 'contact_count' => 9 })
        assert_equal({ full_address: 'Main St 1' },
                     FiltersResponseAttributes.call(attributes: { full_address: 'Main St 1' }, resource_name: 'Customer'),
                     'still readable')
      end

      test 'implicit_entry is the one definition of the entry' do
        assert_equal IMPLICIT, ExtraFieldDefaults.implicit_entry(READ_EDIT)
        assert_equal READ_ONLY, ExtraFieldDefaults.implicit_entry(read_access: true)
        assert_equal READ_ONLY.merge(read_access: false), ExtraFieldDefaults.implicit_entry({})
        assert_equal READ_ONLY.merge(read_access: false), ExtraFieldDefaults.implicit_entry(read_access: 'yes', edit_access: 1),
                     'only true grants'
      end

      # --- ExtraFieldDefaults itself ----------------------------------------------

      test 'adds the implicit entry to the hash it is given and returns it' do
        fields = {}

        assert_same fields, ExtraFieldDefaults.call(entry: { fields: fields, permissions: READ_EDIT }, resource_name: 'Customer')
        assert_equal({ 'full_address' => IMPLICIT, 'contact_count' => IMPLICIT }, fields)
        assert_not_same fields['full_address'], fields['contact_count']
      end

      test 'leaves a name that already has an entry untouched' do
        configured = { read_access: true, edit_access: false, mask_access: true, mask_strategy: 'last4' }
        fields = ExtraFieldDefaults.call(entry: { fields: { 'full_address' => configured.dup }, permissions: READ_EDIT },
                                         resource_name: :Customer)

        assert_equal configured, fields['full_address']
        assert_equal IMPLICIT, fields['contact_count']
      end

      test 'adds nothing for a resource name that is not a model, or a model that declares nothing' do
        assert_empty ExtraFieldDefaults.call(entry: { fields: {}, permissions: READ_EDIT }, resource_name: 'NoSuchModel')
        assert_empty ExtraFieldDefaults.call(entry: { fields: {}, permissions: READ_EDIT }, resource_name: 'Supplier')
      end

      test 'the mode takes an injected configuration' do
        strict = PermissionForge::Configuration.new
        strict.extra_fields_default_access = :unconfigured

        assert_empty ExtraFieldDefaults.call(entry: { fields: {}, permissions: READ_EDIT }, resource_name: 'Customer',
                                             configuration: strict)
      end

      # --- what the filters do with it -----------------------------------------------

      test 'under :unconfigured the permission hash and the filters treat the virtual field as unconfigured' do
        @config.extra_fields_default_access = :unconfigured
        @config.unconfigured_field_strategy = :block
        @user.regenerate_permissions
        Current.user = @user

        assert_nil @user.field_permissions(:Customer, :full_address)
        assert_equal({ name: 'Acme' },
                     FiltersResponseAttributes.call(attributes: { name: 'Acme', full_address: 'Main St 1' }, resource_name: 'Customer'))
        assert_empty PermitsAttributes.call(resource: ::Customer, permitted_params: { full_address: 'Main St 1' })

        @config.unconfigured_field_strategy = :pass_through
        assert_equal 'Main St 1',
                     FiltersResponseAttributes.call(attributes: { full_address: 'Main St 1' }, resource_name: 'Customer')[:full_address]
        assert_empty PermitsAttributes.call(resource: ::Customer, permitted_params: { full_address: 'Main St 1' }),
                     'an unconfigured field is never editable, whatever the read strategy'
      end

      test 'under :grant the filters let the virtual field through' do
        @user.regenerate_permissions
        Current.user = @user

        assert_equal({ full_address: 'Main St 1' },
                     FiltersResponseAttributes.call(attributes: { full_address: 'Main St 1' }, resource_name: 'Customer'))
        assert_equal({ full_address: 'Main St 1' },
                     PermitsAttributes.call(resource: ::Customer, permitted_params: { full_address: 'Main St 1' }))
      end
    end
  end
end
