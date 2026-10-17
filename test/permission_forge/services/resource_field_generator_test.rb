require 'test_helper'

module PermissionForge
  module Services
    class ResourceFieldGeneratorTest < ActiveSupport::TestCase
      setup do
        @permission_set = create_permission_set
        # With Edit: grant_all is not capped to Read-only (FieldLevel.capped).
        @resource = create_resource(permission_set: @permission_set, name: 'Customer', edit_access: true)
      end

      test 'generates fields from model columns' do
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
        field_names = fields.map(&:name)

        assert_includes field_names, 'name'
        assert_includes field_names, 'email'
        assert_includes field_names, 'domain'
        assert_includes field_names, 'supplier_id'
      end

      test 'excludes ignored fields' do
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
        field_names = fields.map(&:name)

        assert_not_includes field_names, 'id'
        assert_not_includes field_names, 'uuid'
      end

      test 'sets read_access and edit_access to false by default' do
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)

        fields.reject { |field| TIMESTAMPS.include?(field.name) }.each do |field|
          assert_not field.read_access, "Expected #{field.name} read_access to be false"
          assert_not field.edit_access, "Expected #{field.name} edit_access to be false"
        end
      end

      test 'grants all access when grant_all is true' do
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource, grant_all: true)

        fields.reject { |field| TIMESTAMPS.include?(field.name) }.each do |field|
          assert field.read_access, "Expected #{field.name} read_access to be true"
          assert field.edit_access, "Expected #{field.name} edit_access to be true"
        end
      end

      # --- Rails timestamps: read-only rows (under :block an unconfigured column is hidden) ---

      TIMESTAMPS = %w[created_at updated_at].freeze

      def generated_timestamps(grant_all:, muting: false)
        set = create_permission_set(name: "Timestamps #{grant_all} #{muting}", is_muting: muting)
        resource = create_resource(permission_set: set, name: 'Customer')
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: resource, grant_all: grant_all)
        TIMESTAMPS.map { |name| fields.find { |row| row.name == name } || flunk("no row for #{name}") }
      end

      test 'with grant_all the timestamps get a read-only, unmasked row' do
        generated_timestamps(grant_all: true).each do |field|
          assert field.read_access, "#{field.name} is readable"
          assert_not field.edit_access, "#{field.name} is never editable"
          assert_not field.mask_access, "#{field.name} is not masked"
        end
      end

      test 'without grant_all the timestamps are hidden like every other column' do
        generated_timestamps(grant_all: false).each do |field|
          assert_not field.read_access, field.name
          assert_not field.edit_access, field.name
          assert_not field.mask_access, field.name
        end
      end

      # On a muting set read on means "take read away": a read-only timestamp
      # row there would mute created_at / updated_at for every holder.
      test 'on a Muting Permission Set the timestamps follow grant_all like every other column' do
        assert(generated_timestamps(grant_all: true, muting: true).all? { |field| field.read_access && field.edit_access })
      end

      # Unchanged mutes nothing, which is what no row means: the generator
      # writes none, as the admin's presets and bulk add never did (FieldLevel.row?).
      test 'without grant_all a Muting Permission Set gets no rows at all, the timestamps included' do
        resource = create_resource(permission_set: create_permission_set(name: 'Muting nothing', is_muting: true), name: 'Customer')

        assert_empty PermissionForge::Services::ResourceFieldGenerator.call(resource: resource, grant_all: false)
        assert_empty resource.resource_fields.reload
      end

      test 'generating fields on a muting set leaves the timestamps readable for its holders' do
        user = create_user
        granting = create_permission_set(name: 'Granting timestamps')
        create_resource(permission_set: granting, name: 'Customer', read_access: true)
        PermissionForge::Services::ResourceFieldGenerator.call(resource: granting.resources.first, grant_all: true)
        muting = create_permission_set(name: 'Muting nothing', is_muting: true)
        muted = create_resource(permission_set: muting, name: 'Customer', read_access: false)
        PermissionForge::Services::ResourceFieldGenerator.call(resource: muted)
        [granting, muting].each { |set| create_permission_set_user(user: user, permission_set: set) }

        fields = user.permissions_hash.dig(:permissions, :resources, :Customer, :fields)
        assert fields.dig(:created_at, :read_access)
        assert fields.dig(:updated_at, :read_access)
      end

      test 'a user granted the generated fields reads the timestamps under :block, and cannot edit them' do
        user = create_user
        create_permission_set_user(user: user, permission_set: @permission_set)
        @resource.update!(read_access: true, edit_access: true)
        PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        user.regenerate_permissions
        created = Time.zone.local(2026, 1, 2, 3, 4, 5)

        PermissionForge.configuration.unconfigured_field_strategy = :block # the library default (the suite runs :warn)
        assert_equal [true, created],
                     AttributeAccessGuard.call(resource_name: :Customer, attribute: :created_at, raw_value: created, user: user)
        assert_equal({ 'created_at' => created },
                     FiltersResponseAttributes.call(attributes: { 'created_at' => created }, resource_name: 'Customer', user: user))
        assert_not user.permissions_hash.dig(:permissions, :resources, :Customer, :fields, :created_at, :edit_access)
      end

      test 'ignored_fields still keeps the timestamps out' do
        PermissionForge.configuration.ignored_fields += TIMESTAMPS
        field_names = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource).map(&:name)

        assert_empty field_names & TIMESTAMPS
      end

      test 'returns empty array when resource name is not a valid class' do
        invalid_resource = create_resource(permission_set: @permission_set, name: 'NonexistentModel')
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: invalid_resource)
        assert_equal [], fields
      end

      # Round 7 (A#127): the label was `name.humanize`, English stored on the
      # row whatever the admin's language. The name is stored; the admin
      # shows the host's translation or the name (GeneratedText).
      test 'labels a generated row with its column name, never the humanized English' do
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)

        assert_equal 'name', fields.find { |f| f.name == 'name' }.label
        assert(fields.all? { |f| f.label == f.name }, fields.map { |f| [f.name, f.label] }.inspect)
      end

      test 'persists fields to the database' do
        expected_count = Customer.column_names.size -
                         PermissionForge.configuration.ignored_fields.count { |f| Customer.column_names.include?(f) } +
                         PermissionForge::VirtualFields.new(Customer).names.size
        assert_difference 'PermissionForge::ResourceField.count', expected_count do
          PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
        end
      end

      # --- GDPR defaults ---

      test 'does not apply GDPR masks when gdpr_defaults is false' do
        PermissionForge.configuration.gdpr_defaults = false
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)

        email_field = fields.find { |f| f.name == 'email' }
        assert_not email_field.mask_access
      end

      # Without grant_all nothing is granted, and a privacy default never
      # grants: the personal-data columns are Hidden like the rest (through
      # 0.14.1 they came back readable and masked). The recommended strategy
      # is on the row for when someone opens them.
      test 'without grant_all gdpr_defaults records the recommended strategy and grants nothing: every row Hidden' do
        PermissionForge.configuration.gdpr_defaults = true
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)

        email_field = fields.find { |f| f.name == 'email' }
        assert_not email_field.read_access
        assert_not email_field.mask_access
        assert_equal 'email', email_field.mask_strategy

        name_field = fields.find { |f| f.name == 'name' }
        assert_not name_field.read_access
        assert_equal 'first1_last4', name_field.mask_strategy

        domain_field = fields.find { |f| f.name == 'domain' }
        assert_not domain_field.read_access
        assert_equal 'full', domain_field.mask_strategy
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'respects custom gdpr_field_patterns' do
        PermissionForge.configuration.gdpr_defaults = true
        original = PermissionForge.configuration.gdpr_field_patterns
        PermissionForge.configuration.gdpr_field_patterns = { /domain/ => 'last4' }

        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)

        domain_field = fields.find { |f| f.name == 'domain' }
        assert_equal 'last4', domain_field.mask_strategy
        assert_not domain_field.read_access

        email_field = fields.find { |f| f.name == 'email' }
        assert_equal 'full', email_field.mask_strategy
      ensure
        PermissionForge.configuration.gdpr_defaults = false
        PermissionForge.configuration.gdpr_field_patterns = original
      end

      # --- Virtual fields ---

      # PermissionForge::ManagedFields: the names the admin's presets and
      # Sync write rows for, under either extra_fields_default_access.
      test 'under :grant virtual fields get a row at the level chosen, as in the admin' do
        PermissionForge.configuration.extra_fields_default_access = :grant
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource).index_by(&:name)

        assert_equal [false, false], fields.fetch('full_address').values_at(:read_access, :edit_access)
        assert_includes fields.keys, 'contact_count'
      end

      test 'grant_all on a Resource without Edit writes Read-only rows (FieldLevel.capped)' do
        resource = create_resource(permission_set: create_permission_set, name: 'Customer', edit_access: false)
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: resource, grant_all: true)

        assert(fields.all? { |field| field.read_access && !field.edit_access && !field.mask_access })
      end

      test 'under :unconfigured virtual fields get a row like columns do' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
        virtual = fields.select { |f| %w[full_address contact_count].include?(f.name) }

        assert_equal %w[contact_count full_address], virtual.map(&:name).sort
        assert(virtual.none? { |f| f.read_access || f.edit_access })
        assert_equal 'full_address', virtual.find { |f| f.name == 'full_address' }.label
      end

      test 'under :unconfigured grant_all keeps full access to virtual fields explicit' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        resource = PermissionForge::Services::ResourceWithFieldsBuilder.call(
          permission_set: create_permission_set, resource_name: 'Customer'
        )
        virtual = resource.resource_fields.find_by(name: 'full_address')

        assert virtual.read_access
        assert virtual.edit_access
      end

      test 'under :unconfigured virtual fields are generated once, Hidden, with the recommended strategy' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        PermissionForge.configuration.gdpr_defaults = true
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
        address = fields.find { |f| f.name == 'full_address' }

        assert_not address.read_access
        assert_equal 'full', address.mask_strategy
        assert_empty PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end
    end
  end
end
