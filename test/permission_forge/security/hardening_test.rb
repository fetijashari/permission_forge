require 'test_helper'

module PermissionForge
  module Security
    # Regression coverage for the 0.10.x security-hardening pass.
    class HardeningTest < ActiveSupport::TestCase
      # --- #6: duplicate resource fields / assignments ---------------------------

      test 'duplicate resource field (same resource + name) is invalid' do
        ps = create_permission_set
        resource = create_resource(permission_set: ps, name: 'Customer', read_access: true)
        create_resource_field(resource: resource, name: 'email', label: 'Email', read_access: true)

        dup = PermissionForge::ResourceField.new(
          uuid: SecureRandom.uuid, name: 'email', label: 'Email 2',
          resource: resource, read_access: true
        )
        refute dup.valid?
        assert dup.errors[:name].present?, 'expected a uniqueness error on name'
      end

      test 'same field name is allowed on a different resource' do
        ps = create_permission_set
        r1 = create_resource(permission_set: ps, name: 'Customer', read_access: true)
        r2 = create_resource(permission_set: ps, name: 'Supplier', read_access: true)
        create_resource_field(resource: r1, name: 'email', read_access: true)

        other = PermissionForge::ResourceField.new(
          uuid: SecureRandom.uuid, name: 'email', label: 'Email', resource: r2, read_access: true
        )
        assert other.valid?
      end

      test 'duplicate permission set user assignment is invalid' do
        user = create_user
        ps = create_permission_set
        create_permission_set_user(user: user, permission_set: ps)

        dup = PermissionForge::PermissionSetUser.new(uuid: SecureRandom.uuid, user: user, permission_set: ps)
        refute dup.valid?
      end

      # --- #4: extra_fields must not clobber a configured field ------------------

      test 'extra field colliding with a configured field does not unmask or grant edit' do
        ps = create_permission_set
        resource = create_resource(permission_set: ps, name: 'Customer', read_access: true)
        create_resource_field(
          resource: resource, name: 'email', label: 'Email',
          read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email'
        )

        fields = with_customer_extra_fields(['email']) { built_customer_fields(ps) }

        entry = fields['email']
        assert_equal true,  entry[:read_access]
        assert_equal false, entry[:edit_access], 'configured edit_access:false must survive extra_fields merge'
        assert_equal true,  entry[:mask_access], 'configured mask_access must survive extra_fields merge'
        assert_equal 'email', entry[:mask_strategy]
      end

      # Symbol names used to slip past the String-keyed collision check and then
      # replace the configured entry when the cache symbolized the hash.
      test 'symbol-named extra field colliding with a configured field does not unmask or grant edit' do
        ps = create_permission_set
        resource = create_resource(permission_set: ps, name: 'Customer', read_access: true)
        create_resource_field(
          resource: resource, name: 'email', label: 'Email',
          read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email'
        )
        user = create_user
        create_permission_set_user(user: user, permission_set: ps)

        with_customer_extra_fields(%i[email]) { user.regenerate_permissions }

        entry = user.field_permissions(:Customer, :email)
        assert_equal true,  entry[:read_access]
        assert_equal false, entry[:edit_access], 'configured edit_access:false must survive a Symbol extra field'
        assert_equal true,  entry[:mask_access], 'configured mask_access must survive a Symbol extra field'
        assert_equal 'email', entry[:mask_strategy]
      end

      test 'symbol-named extra field is stored under a String key' do
        ps = create_permission_set
        create_resource(permission_set: ps, name: 'Customer', read_access: true)

        fields = with_customer_extra_fields(%i[full_address]) { built_customer_fields(ps) }

        assert_equal ['full_address'], fields.keys
      end

      test 'muting set can hide a symbol-named extra field' do
        granting = create_permission_set
        create_resource(permission_set: granting, name: 'Customer', read_access: true)
        muting = create_permission_set(is_muting: true)
        muted = create_resource(permission_set: muting, name: 'Customer', read_access: false)
        create_resource_field(resource: muted, name: 'full_address', label: 'Full address',
                              read_access: true, edit_access: true)
        user = create_user
        [granting, muting].each { |set| create_permission_set_user(user: user, permission_set: set) }

        with_customer_extra_fields(%i[full_address]) { user.regenerate_permissions }

        entry = user.field_permissions(:Customer, :full_address)
        assert_equal false, entry[:read_access]
        assert_equal false, entry[:edit_access]
      end

      # The implicit grant used to be added after each granting set, so a row
      # in a NEWER set lost to the older set's implicit read + edit.
      test 'a configured extra field wins over the implicit grant whichever set is older' do
        %i[bare_first strict_first].each do |order|
          user = create_user
          sets = { bare: nil, strict: nil }
          (order == :bare_first ? %i[bare strict] : %i[strict bare]).each_with_index do |kind, index|
            set = create_permission_set(name: "#{order} #{kind}", created_at: Time.current + index.seconds)
            resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
            if kind == :strict
              create_resource_field(resource: resource, name: 'full_address', label: 'Full address',
                                    read_access: true, edit_access: false, mask_access: true, mask_strategy: 'full')
            end
            create_permission_set_user(user: user, permission_set: set)
            sets[kind] = set
          end
          user.regenerate_permissions

          entry = user.field_permissions(:Customer, :full_address)
          assert_equal true,  entry[:read_access], order
          assert_equal false, entry[:edit_access], "#{order}: the row's edit_access:false must hold"
          assert_equal true,  entry[:mask_access], "#{order}: the row's mask must hold"
        end
      end

      test 'an extra field no set configures still gets the implicit grant once' do
        user = create_user
        2.times do |index|
          set = create_permission_set(name: "Bare #{index}")
          create_resource(permission_set: set, name: 'Customer', read_access: true, edit_access: index.zero?)
          create_permission_set_user(user: user, permission_set: set)
        end
        user.regenerate_permissions

        entry = user.field_permissions(:Customer, :full_address)
        assert_equal({ read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' }, entry)
      end

      # --- #2: audit_trail_enabled is a live runtime toggle ----------------------

      test 'audit_trail_enabled = false at runtime skips created_by attribution' do
        PermissionForge.configuration.audit_trail_enabled = false
        Current.user = create_user

        ps = create_permission_set
        assert_nil ps.created_by_id
      ensure
        Current.reset
      end

      test 'audit_trail_enabled = true at runtime records created_by attribution' do
        PermissionForge.configuration.audit_trail_enabled = true
        actor = create_user
        Current.user = actor

        ps = create_permission_set
        assert_equal actor.id, ps.created_by_id
      ensure
        PermissionForge.configuration.audit_trail_enabled = false
        Current.reset
      end

      # --- #1: conditional_sets_strict_mode fails closed on blank context --------

      test 'strict mode denies a conditional (IP-gated) set when request context is blank' do
        user = create_user
        ps = create_permission_set(allowed_ips: '10.0.0.0/8')
        create_permission_set_user(user: user, permission_set: ps)
        create_resource(permission_set: ps, name: 'Customer', read_access: true)
        PermissionForge.configuration.request_context_resolver = -> { {} }

        PermissionForge.configuration.conditional_sets_strict_mode = false
        user.regenerate_permissions
        assert user.can_read?(:Customer), 'lenient (default): conditional set stays active with blank context'

        PermissionForge.configuration.conditional_sets_strict_mode = true
        user.regenerate_permissions
        refute user.can_read?(:Customer), 'strict: conditional set is inactive with blank context'
      end

      test 'strict mode leaves unconditional sets active' do
        user = create_user
        ps = create_permission_set # no activation conditions
        create_permission_set_user(user: user, permission_set: ps)
        create_resource(permission_set: ps, name: 'Customer', read_access: true)
        PermissionForge.configuration.request_context_resolver = -> { {} }
        PermissionForge.configuration.conditional_sets_strict_mode = true

        user.regenerate_permissions
        assert user.can_read?(:Customer)
      end

      # --- find_by nil contract vs denial ---------------------------------------

      test 'find_by returns nil for a genuinely missing record even when rules apply' do
        user = create_user
        ps = create_permission_set
        create_permission_set_user(user: user, permission_set: ps)
        resource = create_resource(permission_set: ps, name: 'Customer', read_access: true)
        create_permission_set_rule(
          permission_set: ps, resource: resource,
          field_name: 'id', field_value: '-1', operator: 'equal', include_nulls: false
        )
        user.regenerate_permissions
        Current.user = user

        assert_nil ::Customer.find_by(id: 987_654_321), 'missing record must return nil, not raise'
      ensure
        Current.reset
      end

      test 'find_by raises NotAuthorizedError for an existing record denied by a rule' do
        user = create_user
        ps = create_permission_set
        create_permission_set_user(user: user, permission_set: ps)
        resource = create_resource(permission_set: ps, name: 'Customer', read_access: true)
        customer = create_customer
        create_permission_set_rule(
          permission_set: ps, resource: resource,
          field_name: 'id', field_value: '-1', operator: 'equal', include_nulls: false
        )
        user.regenerate_permissions
        Current.user = user

        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          ::Customer.find_by(id: customer.id)
        end
      ensure
        Current.reset
      end

      private

      # The Customer fields the engine builds for one Permission Set, as
      # PermissionHashBuilder leaves them: String keys, before the cache
      # symbolizes the hash.
      def built_customer_fields(permission_set)
        PermissionForge::Services::PermissionHashBuilder
          .call(user: create_user, permission_sets: [permission_set])[:resources]['Customer'][:fields]
      end

      # Swaps Customer.extra_fields_for_permissions for the block (minitest 6
      # ships no stub helper).
      def with_customer_extra_fields(names)
        original = ::Customer.method(:extra_fields_for_permissions)
        replace_singleton_method(::Customer, :extra_fields_for_permissions) { names }
        yield
      ensure
        replace_singleton_method(::Customer, :extra_fields_for_permissions, original)
      end
    end
  end
end
