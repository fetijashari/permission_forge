require 'test_helper'
require_relative '../virtual_field_models'
require_relative '../field_variant_models'
require 'permission_forge/sti_models'

module PermissionForge
  module Admin
    class EffectiveAccessTest < ActiveSupport::TestCase
      setup do
        @user = create_user(name: 'Ana Krasniqi')
        @sales = create_permission_set(name: 'Sales rep')
        @customer = create_resource(permission_set: @sales, read_access: true, edit_access: true)
        create_resource_field(resource: @customer, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: @customer, name: 'name', read_access: true, edit_access: true)
        create_permission_set_user(user: @user, permission_set: @sales)
      end

      def outcome(name = 'Customer')
        EffectiveAccess.call(user: @user).find { |r| r.name == name }
      end

      def field(name, res = outcome)
        res.fields.find { |f| f.name == name }
      end

      # ResourceChain: the rules of every entry a subclass answers to apply,
      # a bypass skips only its own entry's rules — the admin shows the same.
      test 'a subclass entry lists the base entry\'s rules too, and View All on the subclass skips only its own' do
        base = create_resource(permission_set: @sales, name: 'PfStiTicket', read_access: true)
        create_permission_set_rule(permission_set: @sales, resource: base, name: 'Open only', field_name: 'status', field_value: 'open')
        sub = create_resource(permission_set: @sales, name: 'PfStiBugTicket', read_access: true, view_all: true)
        create_permission_set_rule(permission_set: @sales, resource: sub, name: 'Own bugs', field_name: 'owner_id',
                                   field_value: 'current_user')

        res = outcome('PfStiBugTicket')

        assert_equal ['Open only'], res.rules.map { |source| source.rule.name }, 'the base rule applies; the own rule is bypassed'
        assert_equal :rules, res.records
        base.update!(view_all: true)

        assert_empty outcome('PfStiBugTicket').rules
        assert_equal :all, outcome('PfStiBugTicket').records
      end

      # PermissionHashBuilder.granted_flags: a row written past the validation
      # grants edit only with read, Modify All only with View All.
      test 'resource flags follow the engine for a row that grants edit without read' do
        @customer.update_columns(read_access: false, edit_access: true, delete_access: true, view_all: false, modify_all: true)

        res = outcome

        assert_equal :none, res.op(:edit_access).state
        assert_equal :none, res.op(:delete_access).state
        assert_equal :none, res.op(:modify_all).state
        assert_equal :none, res.records
      end

      test 'grants come with the set that gave them' do
        res = outcome

        assert_predicate res.op(:read_access), :granted?
        assert_equal [@sales], res.op(:read_access).granted_by
        assert_equal :none, res.op(:delete_access).state
        assert_equal 'masked', field('email', res).level
        assert_equal 'email', field('email', res).mask_strategy
        assert_equal 'edit', field('name', res).level
      end

      test 'a muting set blocks flags, hides fields and blocks actions, with provenance' do
        create_resource_action(resource: @customer, name: 'export', is_permitted: true)
        contractors = create_permission_set(name: 'Contractors', is_muting: true)
        muted = create_resource(permission_set: contractors, read_access: false, edit_access: true)
        create_resource_field(resource: muted, name: 'name', read_access: true, edit_access: true)
        create_resource_action(resource: muted, name: 'export', is_permitted: true)
        create_permission_set_user(user: @user, permission_set: contractors)

        res = outcome

        assert_predicate res.op(:edit_access), :blocked?
        assert_equal [contractors], res.op(:edit_access).blocked_by
        assert_equal 'hidden', field('name', res).level
        assert_equal [contractors], field('name', res).blocked_by
        assert_equal :blocked, res.actions.to_h.fetch('export').state
      end

      # The WHY panel words each set's say by its level (b-admin-ui round 2 #62).
      test 'each set that grants or mutes a field comes with its own level' do
        support = create_permission_set(name: 'Support')
        create_resource_field(resource: create_resource(permission_set: support), name: 'email', read_access: true)
        create_permission_set_user(user: @user, permission_set: support)
        contractors = create_permission_set(name: 'Contractors', is_muting: true)
        muted = create_resource(permission_set: contractors, read_access: false, edit_access: false)
        create_resource_field(resource: muted, name: 'email', mask_access: true, read_access: false, edit_access: false)
        create_resource_field(resource: muted, name: 'name', read_access: true, edit_access: true)
        create_permission_set_user(user: @user, permission_set: contractors)

        email = field('email')
        name = field('name')

        assert_equal([[support, 'read', 'full'], [@sales, 'masked', 'email']],
                     email.grants.map { |s| [s.permission_set, s.level, s.mask_strategy] })
        assert_equal email.granted_by, email.grants.map(&:permission_set)
        assert_equal([[contractors, 'mask']], email.mutes.map { |s| [s.permission_set, s.level] })
        assert_equal([[contractors, 'hide']], name.mutes.map { |s| [s.permission_set, s.level] })
        assert_equal name.blocked_by, name.mutes.map(&:permission_set)
      end

      test 'a set that masks a field and mutes Read on the resource hides it' do
        contractors = create_permission_set(name: 'Contractors', is_muting: true)
        muted = create_resource(permission_set: contractors, read_access: true, edit_access: false)
        create_resource_field(resource: muted, name: 'email', mask_access: true, read_access: false, edit_access: false)
        create_permission_set_user(user: @user, permission_set: contractors)

        assert_equal([[contractors, 'hide']], field('email').mutes.map { |s| [s.permission_set, s.level] })
      end

      # A muting row with Edit only (API / console) takes editing away, not
      # the field: the WHY panel must not say it hides it. It is credited
      # only where it took editing away (EX: what a set did to the entry).
      test 'a muting row that mutes only edit is no_edit and leaves the field readable' do
        contractors = create_permission_set(name: 'Contractors', is_muting: true)
        muted = create_resource(permission_set: contractors, read_access: false, edit_access: false)
        create_resource_field(resource: muted, name: 'email', read_access: false, edit_access: true)
        create_resource_field(resource: muted, name: 'name', read_access: false, edit_access: true)
        create_permission_set_user(user: @user, permission_set: contractors)
        @customer.resource_fields.find_by!(name: 'email').update!(mask_access: false)

        email = field('email')
        name = field('name')

        assert_empty email.mutes, 'email was not editable: the row changed nothing'
        assert_equal 'read', email.level
        assert_equal([[contractors, 'no_edit']], name.mutes.map { |s| [s.permission_set, s.level] })
        assert_equal 'read', name.level
        assert_predicate name, :visible?
        assert_equal 'Contractors stops people editing this field.',
                     I18n.t('permission_forge.ui.level_sentences.no_edit', set: 'Contractors')
      end

      test 'expired assignments and inactive sets give nothing' do
        other = create_user
        old = create_permission_set(name: 'Old')
        create_resource(permission_set: old)
        create_permission_set_user(user: other, permission_set: old, expires_at: 1.day.ago)
        off = create_permission_set(name: 'Off', is_active: false)
        create_resource(permission_set: off)
        create_permission_set_user(user: other, permission_set: off)

        assert_empty EffectiveAccess.call(user: other)
      end

      test 'conditional sets count and are reported' do
        cond = create_permission_set(name: 'Office', allowed_ips: '10.0.0.0/8')
        create_resource(permission_set: cond, name: 'Supplier')
        create_permission_set_user(user: @user, permission_set: cond)
        service = EffectiveAccess.new(user: @user)
        names = service.call.map(&:name)

        assert_includes names, 'Supplier'
        assert_equal [cond], service.conditional_sets
      end

      test 'unconfigured columns follow unconfigured_field_strategy' do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        assert_equal 'hidden', field('domain').level
        assert field('domain').unconfigured

        PermissionForge.configuration.unconfigured_field_strategy = :pass_through
        assert_equal 'read', field('domain').level

        PermissionForge.configuration.unconfigured_field_strategy = :mask_all
        assert_equal 'masked', field('domain').level
      end

      test 'virtual fields from extra_fields_for_permissions are editable by default' do
        virtual = field('full_address')

        assert virtual.virtual
        assert virtual.implicit
        assert_equal 'edit', virtual.level
        assert_not virtual.unconfigured
        assert_empty virtual.granted_by, 'the level comes from the default, not from a set'
        assert_not field('email').implicit
      end

      test 'under :unconfigured a declared virtual field is listed as unconfigured' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        PermissionForge.configuration.unconfigured_field_strategy = :block
        virtual = field('full_address')

        assert virtual.virtual
        assert virtual.unconfigured
        assert_not virtual.implicit
        assert_equal 'hidden', virtual.level

        PermissionForge.configuration.unconfigured_field_strategy = :pass_through
        assert_equal 'read', field('full_address').level
      end

      test 'a configured virtual field shows its own level in both modes' do
        create_resource_field(resource: @customer, name: 'full_address', read_access: true, mask_access: true)

        %i[grant unconfigured].each do |mode|
          PermissionForge.configuration.extra_fields_default_access = mode
          virtual = field('full_address')
          assert_equal ['masked', true, false, false, [@sales]],
                       [virtual.level, virtual.virtual, virtual.implicit, virtual.unconfigured, virtual.granted_by], "mode #{mode}"
        end
      end

      test 'discovered virtual fields are listed as unconfigured, never as granted' do
        PermissionForge.configuration.virtual_field_discovery = true
        create_resource(permission_set: @sales, name: 'PfVirtualAccount', read_access: true, edit_access: true)

        %i[grant unconfigured].each do |mode|
          PermissionForge.configuration.extra_fields_default_access = mode
          res = outcome('PfVirtualAccount')
          %w[nickname theme].each do |name|
            discovered = field(name, res)
            assert_equal [true, true], [discovered.virtual, discovered.unconfigured], "#{name} in mode #{mode}"
          end
          assert_equal mode == :unconfigured, field('full_address', res).unconfigured
        end
      end

      test 'a muting set hides an implicitly granted virtual field' do
        mute = create_permission_set(name: 'Mute', is_muting: true)
        muted = create_resource(permission_set: mute, read_access: false)
        create_resource_field(resource: muted, name: 'full_address', read_access: true, edit_access: true)
        create_permission_set_user(user: @user, permission_set: mute)
        virtual = field('full_address')

        assert_equal 'hidden', virtual.level
        assert_equal [mute], virtual.blocked_by
      end

      test 'editable fields are shown as read-only when the resource has no Edit' do
        @customer.update!(edit_access: false)
        name = field('name')

        assert_equal 'read', name.level
        assert name.capped
      end

      test 'variants inherit the base field setting' do
        orders = create_resource(permission_set: @sales, name: 'PfVariantOrder', read_access: true)
        create_resource_field(resource: orders, name: 'owner_id', read_access: true)

        assert_equal 'owner_id', field('owner_uuid', outcome('PfVariantOrder')).variant_of
      end

      # owner_id -> owner_uuid is a variant on PfVariantOrder (it has the
      # column); Customer has no supplier_uuid, so supplier_id brings no
      # field: the list and its count are the model's (field test #41, #67).
      test 'no variant field for a name the model does not have, in the engine or here' do
        create_resource_field(resource: @customer, name: 'supplier_id', read_access: true)

        assert_not engine_resource[:fields].key?('supplier_uuid')
        assert_nil field('supplier_uuid')
        assert_field_parity('supplier_id row')
      end

      # A variant tie (owner_id -> owner_uuid next to an owner_uuid row) goes
      # to the explicit owner_uuid row in both, whichever row is older: the
      # row is what the admin wrote (plan-final.md D.1; it used to go to the
      # older row, so an older owner_id row decided owner_uuid).
      test 'a variant tie shows the explicit row the engine uses, in either row order' do
        [%w[owner_uuid owner_id], %w[owner_id owner_uuid]].each_with_index do |order, index|
          tie = create_permission_set(name: "Tie #{index}")
          resource = create_resource(permission_set: tie, name: 'PfVariantOrder', read_access: true)
          strategies = { 'owner_uuid' => 'email', 'owner_id' => 'last4' }
          order.each do |name|
            create_resource_field(resource: resource, name: name, read_access: true, mask_access: true, mask_strategy: strategies[name])
          end
          assignment = create_permission_set_user(user: @user, permission_set: tie)

          engine = engine_resource('PfVariantOrder')

          assert_equal 'email', engine[:fields]['owner_uuid'][:mask_strategy], "#{order.inspect}: the explicit row wins in the engine"
          assert_equal 'email', field('owner_uuid', outcome('PfVariantOrder')).mask_strategy, order.inspect
          assert_nil field('owner_uuid', outcome('PfVariantOrder')).variant_of, 'an explicit row is no variant'
          assert_field_parity("variant tie #{order.inspect}", 'PfVariantOrder')
          assignment.destroy!
        end
      end

      # P5: an explicit Hidden row next to an Editable base row.
      test 'an explicit Hidden row for a variant name is hidden, in the engine and here' do
        tie = create_permission_set(name: 'Hidden variant')
        resource = create_resource(permission_set: tie, name: 'PfVariantOrder', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'owner_id', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'owner_uuid', read_access: false, edit_access: false)
        create_permission_set_user(user: @user, permission_set: tie)

        assert_equal false, engine_resource('PfVariantOrder')[:fields]['owner_uuid'][:read_access]
        assert_equal 'hidden', field('owner_uuid', outcome('PfVariantOrder')).level
        assert_equal 'edit', field('owner_id', outcome('PfVariantOrder')).level
        assert_field_parity('hidden variant row', 'PfVariantOrder')
      end

      test 'records: View All wins over rules, rules otherwise' do
        create_permission_set_rule(permission_set: @sales, resource: @customer)
        assert_equal :rules, outcome.records
        assert_equal 1, outcome.rules.size

        @customer.update!(view_all: true)
        assert_equal :all, outcome.records
      end

      # Parity with the engine: the explanation must never disagree with the
      # permission hash the app actually enforces.
      MODES = %i[grant unconfigured].freeze

      # The engine's entry for one resource, built the way a request builds it.
      def engine_resource(name = 'Customer')
        sets = PermissionForge::PermissionSet.active.where(id: @user.permission_set_users.select(:permission_set_id))
                                             .order(:created_at, :id).to_a
        PermissionForge::Services::PermissionHashBuilder.call(user: @user, permission_sets: sets)[:resources][name]
      end

      # The level the app enforces for one engine field entry (Edit is capped
      # to Read when the resource has no Edit).
      def engine_level(engine, entry)
        level = FieldLevel.effective_level(entry)
        level == 'edit' && !engine[:permissions][:edit_access] ? 'read' : level
      end

      # Every field the engine has an entry for shows the engine's level, and
      # the admin never shows a configured level the engine has no entry for.
      def assert_field_parity(context, name = 'Customer')
        engine = engine_resource(name)
        res = outcome(name)
        expected = engine[:fields].to_h { |field_name, entry| [field_name.to_s, engine_level(engine, entry)] }
        shown = res.fields.reject(&:unconfigured).to_h { |outcome| [outcome.name, outcome.level] }

        assert_equal expected.sort, shown.sort, "#{context}: levels of the fields with an entry"
      end

      test 'flags and field levels match PermissionHashBuilder, in both virtual-field modes' do
        mgr = create_permission_set(name: 'Manager')
        m = create_resource(permission_set: mgr, read_access: true, delete_access: true, view_all: true)
        create_resource_field(resource: m, name: 'email', read_access: true, mask_access: false)
        create_resource_field(resource: m, name: 'domain', read_access: false)
        mute = create_permission_set(name: 'Mute', is_muting: true)
        mr = create_resource(permission_set: mute, read_access: false, delete_access: true)
        create_resource_field(resource: mr, name: 'domain', read_access: false, mask_access: true)
        create_resource_field(resource: mr, name: 'contact_count', read_access: true, edit_access: true)
        [mgr, mute].each { |ps| create_permission_set_user(user: @user, permission_set: ps) }

        MODES.each do |mode|
          PermissionForge.configuration.extra_fields_default_access = mode
          engine = engine_resource
          res = outcome

          EffectiveAccess::RESOURCE_FLAGS.each do |flag|
            assert_equal engine[:permissions][flag], res.op(flag).granted?, "#{mode}: flag #{flag}"
          end
          assert_field_parity(mode)
          assert_equal mode == :grant, engine[:fields].key?('full_address'), "#{mode}: engine entry for the virtual field"
        end
      end

      # The implicit entry is added once per resource, after every granting set
      # is merged: a row in any of the sets wins, whichever set is older.
      test 'a virtual field configured in only one of two sets matches the engine, whichever set is older' do
        [[2.days.ago, 1.day.ago], [1.day.ago, 2.days.ago]].each do |bare_created, strict_created|
          MODES.each do |mode|
            PermissionForge.configuration.extra_fields_default_access = mode
            @user = create_user
            bare = create_permission_set(name: PermissionForge::PermissionSet.unique_name('Bare'), created_at: bare_created)
            create_resource(permission_set: bare, read_access: true, edit_access: true)
            strict = create_permission_set(name: PermissionForge::PermissionSet.unique_name('Strict'), created_at: strict_created)
            row = create_resource(permission_set: strict, read_access: true, edit_access: true)
            create_resource_field(resource: row, name: 'full_address', read_access: true, mask_access: true)
            [bare, strict].each { |ps| create_permission_set_user(user: @user, permission_set: ps) }

            assert_field_parity("#{mode}, bare set #{bare_created < strict_created ? 'older' : 'newer'}")
          end
        end
      end

      # ResourceChain composes a subclass's fields: the strictest entry along
      # the chain decides, and an entry that does not grant read hides every
      # field the chain configures. The admin's view of the subclass shows
      # what the attribute guard enforces (ResourceChain.fields), and says
      # which entry decided.
      def chain_levels(name)
        @user.regenerate_permissions
        names = PermissionForge::ResourceChain.names_for(name)
        editable = PermissionForge::ResourceChain.grants?(@user, names, :edit_access)
        PermissionForge::ResourceChain.fields(@user, names).to_h do |field_name, entry|
          level = FieldLevel.effective_level(entry)
          [field_name.to_s, level == 'edit' && !editable ? 'read' : level]
        end
      end

      def assert_chain_parity(context, name)
        shown = outcome(name).fields.reject(&:unconfigured).to_h { |field| [field.name, field.level] }

        assert_equal chain_levels(name).sort, shown.sort, "#{context}: the subclass's fields as ResourceChain composes them"
      end

      test 'a subclass shows its fields as the chain composes them: the strictest entry decides' do
        base = create_resource(permission_set: @sales, name: 'PfStiTicket', read_access: true, edit_access: true)
        create_resource_field(resource: base, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: base, name: 'secret', read_access: true)
        create_resource_field(resource: base, name: 'status', read_access: true, edit_access: true)
        sub = create_resource(permission_set: @sales, name: 'PfStiBugTicket', read_access: true, edit_access: true)
        create_resource_field(resource: sub, name: 'email', read_access: true, edit_access: true)
        create_resource_field(resource: sub, name: 'title', read_access: true, edit_access: true)
        create_resource_field(resource: sub, name: 'status', read_access: false)

        res = outcome('PfStiBugTicket')

        assert_equal 'masked', field('email', res).level, 'the base masks it: the strictest entry wins'
        assert_equal 'email', field('email', res).mask_strategy
        assert_equal 'PfStiTicket', field('email', res).decided_by
        assert_equal([[@sales, 'masked']], field('email', res).grants.map { |source| [source.permission_set, source.level] })
        assert_equal 'read', field('secret', res).level, 'configured on the base only'
        assert_equal 'PfStiTicket', field('secret', res).decided_by
        assert_equal 'edit', field('title', res).level
        assert_nil field('title', res).decided_by, 'its own entry decides'
        assert_equal 'hidden', field('status', res).level
        assert_chain_parity('strictest', 'PfStiBugTicket')
      end

      test 'a base entry that does not grant read hides every field of the subclass, as the engine does' do
        create_resource(permission_set: @sales, name: 'PfStiTicket', read_access: false)
        sub = create_resource(permission_set: @sales, name: 'PfStiBugTicket', read_access: true, edit_access: true)
        create_resource_field(resource: sub, name: 'title', read_access: true, edit_access: true)

        title = field('title', outcome('PfStiBugTicket'))

        assert_equal 'hidden', title.level
        assert_equal 'PfStiTicket', title.decided_by
        assert_empty title.grants, 'no set makes it readable'
        assert_chain_parity('unreadable base', 'PfStiBugTicket')
      end

      test 'discovered virtual fields match the engine in both modes' do
        PermissionForge.configuration.virtual_field_discovery = true
        res = create_resource(permission_set: @sales, name: 'PfVirtualAccount', read_access: true, edit_access: true)
        create_resource_field(resource: res, name: 'theme', read_access: true)

        MODES.each do |mode|
          PermissionForge.configuration.extra_fields_default_access = mode
          assert_field_parity(mode, 'PfVirtualAccount')
        end
      end
    end
  end
end
