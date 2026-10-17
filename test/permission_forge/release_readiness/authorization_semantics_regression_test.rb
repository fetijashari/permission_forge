# frozen_string_literal: true

require 'test_helper'
require 'pp'
require 'permission_forge/sti_models'
require_relative '../nested_attribute_models'

# A host controller for an STI subclass Resource, guarded on its REST actions.
class PfRrSemanticsBugTicketsController < ActionController::Base
  include PermissionForge::Concerns::ControllerActionGuard

  permission_forge_actions resource: 'PfStiBugTicket', rest_actions: true
end

module PermissionForge
  module ReleaseReadiness
    # Pre-release re-review findings on authorization semantics: CS-1 and CS-7
    # (the muting phase of the permission hash, and the admin's explanation
    # of it), CS-4 (the attribute guard with nobody signed in), CQ-N2 (nested
    # `_destroy`), CQ-N3 (inspect) and CQ-N1 for the masking concern (the
    # names it adds to host models). Through the public entry points, from
    # the failing user's side. Each test failed on 918a8ce.
    class AuthorizationSemanticsRegressionTest < ActiveSupport::TestCase
      class GuardedCustomer < ::Customer
        include PermissionForge::Concerns::MaskedAttributes

        def self.name = 'Customer'
      end

      SECRET = 'secret@acme.com'
      # A resource row that grants nothing until a test says otherwise.
      CLOSED = { read_access: false, create_access: false, edit_access: false, delete_access: false }.freeze

      setup do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        @user = create_user
        @sets = 0
      end

      teardown do
        Current.user = nil
        PermissionForge.configuration.masked_attributes_nil_user_strategy = :bypass
      end

      # A granting or muting set of the user with one resource row and its
      # rows (fields:, actions:, rule:); sets merge in creation order, so
      # each gets a later created_at than the one before.
      def grant(name, muting: false, resource: {}, **rows)
        @sets += 1
        set = create_permission_set(name: "#{muting ? 'Mute' : 'Grant'} #{@sets}", is_muting: muting,
                                    created_at: 1.hour.ago + @sets.minutes)
        create_permission_set_user(user: @user, permission_set: set)
        create_rows(set, create_resource(permission_set: set, name: name, **CLOSED, **resource), **rows)
        set
      end

      def create_rows(set, row, fields: {}, actions: {}, rule: nil)
        fields.each { |field, attrs| create_resource_field(resource: row, name: field.to_s, label: field.to_s, **attrs) }
        actions.each { |action, permitted| create_resource_action(resource: row, name: action.to_s, is_permitted: permitted) }
        create_permission_set_rule(permission_set: set, resource: row, **rule) if rule
      end

      def sign_in
        Current.user = User.find(@user.id)
      end

      def entry(name)
        Current.user.permissions_hash.dig(:permissions, :resources, name.to_sym)
      end

      def decision(action)
        PermissionForge::ControllerActions::Authorizer.call(
          controller_path: 'pf_rr_semantics_bug_tickets', action_name: action,
          controller_class: PfRrSemanticsBugTicketsController, user: Current.user
        )
      end

      def effective(name)
        PermissionForge::Admin::EffectiveAccess.call(user: @user).find { |outcome| outcome.name == name.to_s }
      end

      def effective_field(name, field)
        effective(name).fields.find { |outcome| outcome.name == field.to_s }
      end

      # The admin's explanation never disagrees with the hash the app
      # enforces: flags, field levels (Edit is capped to Read when the
      # resource has no Edit) and actions.
      def assert_parity(name)
        engine = entry(name)
        shown = effective(name)
        assert_flag_parity(engine, shown, name)
        assert_field_parity(engine, shown, name)
        assert_action_parity(engine, shown, name)
      end

      def assert_flag_parity(engine, shown, name)
        PermissionForge::Admin::EffectiveAccess::RESOURCE_FLAGS.each do |flag|
          assert_equal engine[:permissions][flag] == true, shown.op(flag).granted?, "#{name} #{flag}"
        end
      end

      # The fields as the attribute guard reads them: composed along the STI
      # chain (ResourceChain.fields), not the entry alone.
      def assert_field_parity(engine, shown, name)
        fields = PermissionForge::ResourceChain.fields(Current.user, PermissionForge::ResourceChain.names_for(name))
        levels = fields.to_h { |field, field_entry| [field.to_s, engine_level(engine, field_entry)] }
        assert_equal levels.sort, shown.fields.reject(&:unconfigured).to_h { |f| [f.name, f.level] }.sort, "#{name} fields"
      end

      def assert_action_parity(engine, shown, name)
        actions = engine[:actions].to_h { |action, action_entry| [action.to_s, action_entry[:is_permitted] == true] }
        assert_equal actions.sort, shown.actions.to_h { |action, outcome| [action, outcome.granted?] }.sort, "#{name} actions"
      end

      def engine_level(engine, field_entry)
        level = PermissionForge::Admin::FieldLevel.effective_level(field_entry)
        level == 'edit' && !engine[:permissions][:edit_access] ? 'read' : level
      end

      # A guarded Customer the user may read: name in full, email masked,
      # domain hidden.
      def customer_with_rows
        grant('Customer', resource: { read_access: true },
                          fields: { name: { read_access: true }, domain: { read_access: false },
                                    email: { read_access: true, mask_access: true, mask_strategy: 'email' } })
        record = GuardedCustomer.create!(uuid: SecureRandom.uuid, name: 'Acme', email: SECRET, domain: 'hidden.example')
        GuardedCustomer.find(record.id)
      end

      # ---- CS-1: a muting set naming an STI base reaches the subclass entries ------

      # Offboarding: the user holds PfStiTicket and, through another set,
      # PfStiBugTicket (same table). A muting set names the base. Rows and
      # fields already followed the chain; the CRUD flags, the bypasses and
      # the actions of the subclass entry did not, so the guard let the
      # subclass controller destroy the row the admin believed muted.
      test 'CS-1 muting the STI base revokes the subclass entry too, and the guard denies' do
        grant('PfStiTicket', resource: { read_access: true, delete_access: true }, fields: { title: { read_access: true } })
        grant('PfStiBugTicket', resource: { read_access: true, edit_access: true, delete_access: true, view_all: true },
                                fields: { secret: { read_access: true, edit_access: true } }, actions: { escalate: true })
        mute = grant('PfStiTicket', muting: true, actions: { escalate: true },
                                    resource: { read_access: true, edit_access: true, delete_access: true, view_all: true })
        sign_in

        %i[PfStiTicket PfStiBugTicket].each do |name|
          assert_not Current.user.can_read?(name), "#{name} read"
          assert_not Current.user.can_edit?(name), "#{name} edit"
          assert_not Current.user.can_delete?(name), "#{name} delete"
          assert_not Current.user.can_view_all?(name), "#{name} view_all"
        end
        assert_not Current.user.can?(:escalate, :PfStiBugTicket)
        subclass = entry(:PfStiBugTicket)
        assert_equal({ read_access: false, edit_access: false }, subclass[:fields][:secret].slice(:read_access, :edit_access))
        assert_includes subclass[:source_permission_sets].map { |set| set[:uuid] }, mute.uuid
        %w[index show update destroy].each { |action| assert_predicate decision(action), :denied?, "guard #{action}" }
        assert_equal :crud_denied, decision('destroy').reason
        assert_parity(:PfStiBugTicket)
        assert_parity(:PfStiTicket)
      end

      # A muting base row that mutes edit alone, with a field row and an
      # action row: the subclass entry loses exactly that and keeps the rest;
      # the admin says the same. A muting row naming the subclass does not
      # reach the base.
      test 'CS-1 a partial mute on the base reaches the subclass entry exactly, never the other way round' do
        grant('PfStiTicket', resource: { read_access: true, edit_access: true, delete_access: true },
                             fields: { title: { read_access: true, edit_access: true } })
        grant('PfStiBugTicket', resource: { read_access: true, edit_access: true, delete_access: true },
                                fields: { secret: { read_access: true, edit_access: true }, title: { read_access: true } },
                                actions: { escalate: true, archive: true })
        mute = grant('PfStiTicket', muting: true, resource: { edit_access: true },
                                    fields: { secret: { read_access: true, edit_access: true } }, actions: { escalate: true })
        grant('PfStiBugTicket', muting: true, resource: { delete_access: true })
        sign_in

        subclass = entry(:PfStiBugTicket)
        assert_equal({ read_access: true, create_access: false, edit_access: false, delete_access: false,
                       view_all: false, modify_all: false }, subclass[:permissions])
        assert_equal({ read_access: false, edit_access: false }, subclass[:fields][:secret].slice(:read_access, :edit_access))
        assert subclass[:fields][:title][:read_access]
        assert_equal false, subclass[:actions][:escalate][:is_permitted]
        assert_equal true, subclass[:actions][:archive][:is_permitted]
        base = entry(:PfStiTicket)
        assert base[:permissions][:delete_access], 'a mute naming the subclass does not reach the base'
        assert_not base[:permissions][:edit_access]

        outcome = effective(:PfStiBugTicket)
        assert_equal [mute], outcome.op(:edit_access).blocked_by
        assert_predicate outcome.op(:read_access), :granted?
        assert_equal [mute], effective_field(:PfStiBugTicket, :secret).blocked_by
        assert_equal [mute], outcome.actions.to_h['escalate'].blocked_by
        assert_parity(:PfStiBugTicket)
        assert_parity(:PfStiTicket)
      end

      # ---- CS-7: a muting field row that mutes read mutes edit too ------------------

      # The admin UI's Hide writes read + edit; the API and code can write a
      # muting row with read_access alone. Such a row hid the field but left
      # it writable through PermitsAttributes.
      test 'CS-7 a muting field row that mutes read also mutes edit' do
        grant('Customer', resource: { read_access: true, edit_access: true },
                          fields: { email: { read_access: true, edit_access: true }, name: { read_access: true, edit_access: true } })
        mute = grant('Customer', muting: true, fields: { email: { read_access: true, edit_access: false } })
        sign_in

        email = entry(:Customer)[:fields][:email]
        assert_equal({ read_access: false, edit_access: false }, email.slice(:read_access, :edit_access))
        assert_equal({ name: 'x' },
                     PermissionForge::Services::PermitsAttributes.call(resource: Customer, permitted_params: { name: 'x', email: 'y' }))
        assert_equal 'hidden', effective_field(:Customer, :email).level
        assert_equal [mute], effective_field(:Customer, :email).blocked_by
        assert_parity(:Customer)
      end

      # ---- CS-4: masking with nobody signed in --------------------------------------

      test 'CS-4 limit: by default the getters return the stored values with no user, whatever nil_user_strategy says' do
        customer = customer_with_rows
        Current.user = nil
        PermissionForge.configuration.nil_user_strategy = :deny

        assert_equal :bypass, PermissionForge::Configuration.new.masked_attributes_nil_user_strategy
        assert_equal 'hidden.example', customer.domain
        assert_equal SECRET, customer.as_json['email']
        capture_io do # explain_all prints its table
          assert_equal :no_user_bypassed, PermissionForge::Concerns::MaskedAttributes.explain_all(customer)
                                                                                     .find { |row| row[:attribute] == 'domain' }[:decision]
        end
      end

      test 'CS-4 masked_attributes_nil_user_strategy = :hide hides every guarded attribute with no user' do
        customer = customer_with_rows
        Current.user = nil
        PermissionForge.configuration.masked_attributes_nil_user_strategy = :hide

        assert_nil customer.domain
        assert_nil customer.email
        assert_nil customer.name, 'configured or not: there is no user whose entry could grant it'
        assert_nil customer[:email]
        assert_nil customer.read_attribute(:email)
        assert_equal customer.id, customer.as_json['id'], 'the primary key is never guarded'
        assert_equal %w[id], customer.as_json.keys
        assert_equal({ 'id' => customer.id }, customer.attributes, 'attributes keeps the primary key, as as_json does')
        assert_equal SECRET, customer.read_attribute_before_type_cast(:email), 'the raw paths stay raw, as documented'
        text = customer.inspect
        assert_not_includes text, SECRET
        assert_not_includes text, 'hidden.example'
        capture_io do # explain_all prints its table
          assert_equal :no_user_hidden, PermissionForge::Concerns::MaskedAttributes.explain_all(customer)
                                                                                   .find { |row| row[:attribute] == 'email' }[:decision]
        end

        PermissionForge.configuration.omit_hidden_in_attributes_hash = false
        assert_equal({ 'email' => nil, 'domain' => nil }, customer.attributes.slice('email', 'domain'))
        assert_nil customer.as_json['email']
      ensure
        PermissionForge.configuration.omit_hidden_in_attributes_hash = true
      end

      test 'CS-4 :hide changes nothing for a signed-in user' do
        customer = customer_with_rows
        PermissionForge.configuration.masked_attributes_nil_user_strategy = :hide
        sign_in

        assert_equal 'Acme', customer.name
        assert_equal 's***@acme.com', customer.email
        assert_nil customer.domain
        assert_equal %w[id name email], customer.as_json.keys & %w[id name email domain]
      end

      test 'CS-4 :hide reaches a wrapped virtual reader and a store accessor' do
        customer = customer_with_rows
        PermissionForge.configuration.mask_virtual_attributes = :auto
        GuardedCustomer.pf_mask_virtual_readers
        Current.user = nil
        PermissionForge.configuration.masked_attributes_nil_user_strategy = :hide

        assert_nil customer.full_address
        assert_equal('Acme, hidden.example', customer.pf_without_virtual_masking { customer.full_address })
      end

      test 'CS-4 the security audit reports masking that bypasses with no user, medium, in every environment' do
        config = PermissionForge::Configuration.new
        config.user_class = 'User'
        checks = [PermissionForge::Services::SecurityAuditChecks::ConfigCheck]
        %w[test production].each do |environment|
          finding = PermissionForge::Services::SecurityAudit.call(configuration: config, checks: checks, environment: environment)
                                                            .findings.find { |f| f.code == :masked_nil_user_bypass }
          assert_equal :medium, finding&.severity, environment
          assert_includes finding.detail, 'masked_attributes_nil_user_strategy'
        end

        config.masked_attributes_nil_user_strategy = :hide
        codes = PermissionForge::Services::SecurityAudit.call(configuration: config, checks: checks).findings.map(&:code)
        assert_not_includes codes, :masked_nil_user_bypass
      end

      test 'CS-4 the generated initializer sets :hide_in_requests and names :hide with the trade-off; the admin lists the setting' do
        template = render_install_template('initializer.rb.tt')
        assert_match(/^  config\.masked_attributes_nil_user_strategy = :hide_in_requests$/, template)
        section = template[template.index('# Masked attributes with nobody signed in'), 700]
        assert_match(/:hide hides in jobs too/, section)
        assert_match(/web request with nobody signed in/, section)
        assert_match(/deliver_now/, section)
        assert_match(/sign a system user in/, section)

        PermissionForge.configuration.masked_attributes_nil_user_strategy = :hide
        row = PermissionForge::Admin::SettingsCatalog.new.row(:masked_attributes_nil_user_strategy)
        assert_predicate row, :ok?
        assert_predicate row, :changed?
      end

      # ---- CQ-N2: nested _destroy ---------------------------------------------------

      def nested_grant(supplier: {}, customer: {}, rule: nil)
        grant('Customer', resource: { read_access: true, edit_access: true, **customer },
                          fields: { name: { read_access: true, edit_access: true } }, rule: rule)
        grant('Supplier', resource: { read_access: true, edit_access: true, **supplier },
                          fields: { name: { read_access: true, edit_access: true } })
        sign_in
      end

      def permitted(params)
        PermissionForge::Services::PermitsAttributes.call(resource: PfNestedCustomer, permitted_params: params)
      end

      # Every key of the nested payload is editable or names the record, so
      # the output is the input: `_destroy` included, for a new record (do
      # not create) and an existing one (destroy).
      test 'CQ-N2 nested _destroy is kept for a user who may delete the child resource' do
        nested_grant(supplier: { delete_access: true })
        supplier = create_supplier
        params = { name: 'x', contacts_attributes: [{ id: '', name: 'new', _destroy: '1' }, { id: supplier.id.to_s, _destroy: '1' }] }

        assert_equal params, permitted(params)
      end

      test 'CQ-N2 nested _destroy is dropped, and reported, for a user who may not delete the child resource' do
        nested_grant
        supplier = create_supplier
        params = { name: 'x', contacts_attributes: [{ id: supplier.id.to_s, name: 'renamed', _destroy: '1' }] }
        PermissionForge.configuration.audit_runtime_events = %i[denied params_filtered]

        assert_equal({ name: 'x', contacts_attributes: [{ id: supplier.id.to_s, name: 'renamed' }] }, permitted(params))
        assert_audit_event('params.filtered', data: { 'reason' => 'field_access', 'dropped' => ['contacts_attributes.*._destroy'] })
      end

      test 'CQ-N2 a belongs_to record whose id the child rules deny is dropped whole, _destroy or not' do
        nested_grant(customer: { delete_access: true }, rule: { field_name: 'supplier_id', field_value: 'current_user', include_nulls: false })
        mine = create_customer(supplier_id: @user.id)
        theirs = create_customer(supplier_id: @user.id + 1000)

        assert_equal({ sibling_attributes: { id: mine.id.to_s, _destroy: '1' } },
                     permitted({ sibling_attributes: { id: mine.id.to_s, _destroy: '1' } }))
        assert_equal({}, permitted({ sibling_attributes: { id: theirs.id.to_s, _destroy: '1' } }))
      end

      test 'CQ-N2 _destroy on the top-level record is not a field and is dropped' do
        nested_grant(customer: { delete_access: true })

        assert_equal({ name: 'x' }, permitted({ name: 'x', _destroy: '1' }))
      end

      # ---- CQ-N3: inspect never raises ----------------------------------------------

      # inspect runs inside error reporters and rescue blocks. A read that
      # fails already printed the hidden value; Rails' own formatting of the
      # value (a private method, renamed some day) ran outside that rescue.
      test 'CQ-N3 inspect and pretty_print never raise, also when Rails fails to format the value' do
        customer = customer_with_rows
        sign_in
        customer.define_singleton_method(:format_for_inspect) { |*| raise ArgumentError, 'renamed in this Rails' }

        text = customer.inspect
        assert_kind_of String, text
        assert_not_includes text, SECRET
        assert_not_includes text, 'hidden.example'
        assert_includes text, 'email: nil'
        assert_kind_of String, customer.pretty_inspect
        assert_not_includes customer.pretty_inspect, SECRET
      end

      # ---- CQ-N1: the names the masking concern adds to host models -----------------

      # Overrides of methods Rails calls by name. Everything else the
      # concern adds to a host model is pf_-prefixed, so a host method of
      # the same name can never replace a piece of the guard.
      # Q8: + read_attribute_for_validation and run_validations! (validators read stored values).
      RAILS_OVERRIDES = %w[read_attribute attributes serializable_hash attribute_names_for_serialization
                           read_attribute_for_serialization read_attribute_for_validation run_validations!
                           attribute_for_inspect pretty_print read_store_attribute write_store_attribute].freeze
      RAILS_CLASS_OVERRIDES = %w[alias_attribute define_attribute_methods].freeze

      def masking_modules(ancestors)
        ancestors.select { |mod| mod.name.to_s.start_with?('PermissionForge::Concerns::MaskedAttributes') }
      end

      def methods_of(mod)
        (mod.instance_methods(false) + mod.private_instance_methods(false)).map(&:to_s).uniq
      end

      # "Module#name" for every method of the modules that is neither
      # pf_-prefixed nor one of the overrides.
      def offenders(modules, overrides, separator)
        modules.flat_map { |mod| methods_of(mod).map { |name| [mod.name, name] } }
               .reject { |_, name| name.start_with?('pf_') || overrides.include?(name) }
               .map { |mod_name, name| "#{mod_name}#{separator}#{name}" }
      end

      test 'CQ-N1 every method the masking concern adds to a host model is pf_-prefixed or a Rails override' do
        instance_modules = masking_modules(GuardedCustomer.ancestors)
        class_modules = masking_modules(GuardedCustomer.singleton_class.ancestors)
        assert_operator instance_modules.size, :>=, 5, instance_modules.inspect
        assert_operator class_modules.size, :>=, 3, class_modules.inspect

        assert_empty offenders(instance_modules, RAILS_OVERRIDES, '#')
        assert_empty offenders(class_modules, RAILS_CLASS_OVERRIDES, '.')
      end
    end
  end
end
