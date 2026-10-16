require 'test_helper'
require_relative '../virtual_field_models'

module PermissionForge
  module Admin
    class FieldLevelTest < ActiveSupport::TestCase
      test 'round-trips every granting and muting level through flags' do
        { false => FieldLevel::GRANTING, true => FieldLevel::MUTING }.each do |muting, map|
          map.each do |level, flags|
            field = PermissionForge::ResourceField.new(flags)
            assert_equal level, FieldLevel.level_of(field, muting: muting)
          end
        end
      end

      test 'rejects unknown levels' do
        assert_raises(ArgumentError) { FieldLevel.flags_for('nope', muting: false) }
        assert_not FieldLevel.valid?('hide', muting: false)
      end
    end

    class ExpiryPresetsTest < ActiveSupport::TestCase
      test 'uses calendar days and end of day' do
        today = Date.new(2026, 3, 28) # DST weekend in Europe
        assert_equal Date.new(2026, 3, 29), ExpiryPresets.date_for('1d', today: today)
        assert_equal Date.new(2026, 3, 31), ExpiryPresets.date_for('eom', today: today)
        assert_nil ExpiryPresets.date_for('never', today: today)
        assert_equal 23, ExpiryPresets.expires_at_for('1w', today: today).hour
      end

      test 'custom dates must be in the future' do
        assert_raises(ExpiryPresets::InvalidDate) { ExpiryPresets.date_for('custom', custom: '') }
        assert_raises(ExpiryPresets::InvalidDate) { ExpiryPresets.date_for('custom', custom: Time.zone.today.iso8601) }
        assert_equal Time.zone.today + 5, ExpiryPresets.date_for('custom', custom: (Time.zone.today + 5).iso8601)
      end
    end

    class PersonLabelTest < ActiveSupport::TestCase
      test 'name, email and initials' do
        label = PersonLabel.new(create_user(name: 'Ana Krasniqi', email: 'ana@acme.test'))

        assert_equal 'Ana Krasniqi', label.name
        assert_equal 'ana@acme.test', label.secondary
        assert_equal 'AK', label.initials
        assert_equal 'Ana', label.first_name
      end

      # f-fixes-verified #12: "dave@acme.test" read "DT" (first and last word of "dave acme test").
      test 'an email label takes its initials from the local part' do
        assert_equal 'DA', PersonLabel.new(create_user(name: nil, email: 'dave@acme.test')).initials
        assert_equal 'DS', PersonLabel.new(create_user(name: nil, email: 'dave.smith@acme.test')).initials
      end

      # a-onboarding #42: the first word of "User #2" or of an email is no first name.
      test 'first_name is the whole label when the label is the email or the fallback' do
        email_only = create_user(name: nil, email: 'dave@acme.test')
        nameless = create_user(name: nil, email: nil)

        assert_equal 'dave@acme.test', PersonLabel.new(email_only).first_name
        assert_equal "User ##{nameless.id}", PersonLabel.new(nameless).first_name
        assert_equal 'Ana', PersonLabel.new(create_user(name: 'Ana Krasniqi')).first_name
      end

      test 'honors user_label_formatter' do
        PermissionForge.configuration.user_label_formatter = ->(u) { "Dr. #{u.name}" }

        assert_equal 'Dr. Bo', PersonLabel.new(create_user(name: 'Bo')).name
      end
    end

    class PeopleDirectoryTest < ActiveSupport::TestCase
      setup do
        @ana = create_user(name: 'Ana Krasniqi', email: 'ana@acme.test')
        @bo = create_user(name: 'Bo Berisha', email: 'bo@acme.test')
        set = create_permission_set
        create_permission_set_user(user: @ana, permission_set: set, expires_at: 3.days.from_now)
      end

      test 'searches by name or email and filters' do
        dir = PeopleDirectory.new

        assert_equal [@ana], dir.search(query: 'krasn').people
        assert_equal [@bo], dir.search(query: 'bo@').people
        assert_includes dir.search(filter: 'ending').people, @ana
        assert_includes dir.search(filter: 'no_access').people, @bo
        assert_not_includes dir.search(filter: 'no_access').people, @ana
        assert_equal 1, dir.counts(query: 'ana')['all']
      end

      test 'pages results' do
        page = PeopleDirectory.new.search(per_page: 1)

        assert_equal 1, page.people.size
        assert_predicate page, :more?
      end
    end

    class SettingsCatalogTest < ActiveSupport::TestCase
      test 'never exposes secrets or hook source' do
        resolver = PermissionForge.configuration.current_user_resolver
        PermissionForge.configuration.current_user_resolver = -> { Current.user }
        PermissionForge.configuration.http_basic_auth_user = 'admin'
        PermissionForge.configuration.http_basic_auth_password = 's3cret'
        catalog = SettingsCatalog.new

        assert_equal true, catalog.row(:http_basic_auth_password).value
        assert_equal :custom, catalog.row(:current_user_resolver).hook_state
        assert_equal :default, catalog.row(:user_list_resolver).hook_state
        assert_not_includes catalog.rows.map { |r| r.value.to_s }.join, 's3cret'
      ensure
        PermissionForge.configuration.current_user_resolver = resolver
        PermissionForge.configuration.http_basic_auth_user = nil
        PermissionForge.configuration.http_basic_auth_password = nil
      end

      test 'flags risky values and recommends safe ones' do
        PermissionForge.configuration.unconfigured_field_strategy = :pass_through
        catalog = SettingsCatalog.new
        row = catalog.row(:unconfigured_field_strategy)

        assert_predicate row, :warn?
        assert_predicate row, :changed?
        assert_equal ':block', catalog.snippet_value(row)
        assert_includes catalog.risky_rows.map(&:key), 'conditional_sets_strict_mode'
      end

      test 'every definition has copy in every bundled locale' do
        SettingsCatalog::DEFINITIONS.each do |d|
          PermissionForge::BUNDLED_LOCALES.each do |locale|
            assert I18n.exists?("permission_forge.settings.items.#{d.key}.name", locale), "#{locale} #{d.key}"
          end
        end
      end
    end

    class AuditTrailTest < ActiveSupport::TestCase
      test 'csv escapes quotes and neutralises formulas' do
        csv = AuditTrail.new.to_csv([], describe: nil, person: nil)
        assert csv.start_with?('Type,Record,Where')

        assert_equal %("a ""b"", c"), Csv.cell('a "b", c')
        assert_equal "'=SUM(A1)", Csv.cell('=SUM(A1)')
      end

      test 'lists a set and its children, filtered by type' do
        set = create_permission_set
        res = create_resource(permission_set: set)
        create_resource_field(resource: res)
        trail = AuditTrail.new

        assert_equal %w[field permission_set resource], trail.for_permission_set(set).map(&:type).uniq.sort
        assert_equal %w[field], trail.for_permission_set(set, type: 'field').map(&:type)
      end
    end

    class AttentionItemsTest < ActiveSupport::TestCase
      setup { PermissionForge.configuration.unconfigured_field_strategy = :block }

      test 'finds ending, expired, stale, tidy and unmasked sensitive items' do
        user = create_user
        set = create_permission_set(name: 'Sales')
        res = create_resource(permission_set: set)
        create_resource_field(resource: res, name: 'email', read_access: true, mask_access: false)
        create_permission_set_user(user: user, permission_set: set, expires_at: 2.days.from_now)
        create_permission_set_user(user: create_user, permission_set: set, expires_at: 2.days.ago)
        stale = create_permission_set_user(user: create_user, permission_set: set)
        stale.update_columns(created_at: 200.days.ago)
        create_permission_set(name: 'Empty')
        items = AttentionItems.new

        assert_equal 1, items.ending_soon.size
        assert_equal 1, items.expired.size
        assert_equal [stale], items.stale
        assert_equal(['Empty'], items.tidy.map { |t| t.permission_set.name })
        assert_equal %w[email full_address], items.privacy_findings.map(&:name)
        assert_not_predicate items, :all_good?
      end

      test 'acknowledged fields are no longer flagged' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        res = create_resource(permission_set: create_permission_set)
        create_resource_field(resource: res, name: 'email', read_access: true, sensitive_acknowledged_at: Time.current)

        assert_empty AttentionItems.new.privacy_findings
      end

      test 'a sensitive virtual field left on the implicit grant is a privacy finding' do
        set = create_permission_set(name: 'Sales')
        res = create_resource(permission_set: set)
        create_permission_set_user(user: create_user, permission_set: set)
        finding = AttentionItems.new.privacy_findings.sole

        assert_equal ['full_address', res, 1], [finding.name, finding.resource, finding.people_count]
        assert_predicate finding, :implicit_grant?
        assert_predicate finding, :unconfigured?
        assert_not_predicate finding, :turned_off?
      end

      test 'a virtual field with a row is judged by that row, like a column' do
        res = create_resource(permission_set: create_permission_set)
        field = create_resource_field(resource: res, name: 'full_address', read_access: true, mask_access: true)
        assert_empty AttentionItems.new.privacy_findings

        field.update!(mask_access: false)
        finding = AttentionItems.new.privacy_findings.sole
        assert_equal field, finding.field
        assert_not_predicate finding, :implicit_grant?
        assert_not_predicate finding, :unconfigured?
        assert_not_predicate finding, :turned_off?
      end

      # The engine skips a switched-off row, so the field is back on whatever
      # applies to a field with no row. The finding keeps the row, so the card
      # can say it is turned off instead of "not configured".
      test 'a switched-off row leaves a sensitive virtual field on the implicit grant' do
        set = create_permission_set(name: 'Sales')
        res = create_resource(permission_set: set)
        user = create_user
        create_permission_set_user(user: user, permission_set: set)
        row = create_resource_field(resource: res, name: 'full_address', read_access: false, is_active: false)
        user.regenerate_permissions

        assert_equal Services::ExtraFieldDefaults.implicit_entry(read_access: true), user.field_permissions(:Customer, :full_address)
        finding = AttentionItems.new.privacy_findings.sole
        assert_equal ['full_address', res, 1], [finding.name, finding.resource, finding.people_count]
        assert_predicate finding, :implicit_grant?
        assert_predicate finding, :unconfigured?
        assert_predicate finding, :turned_off?
        assert_equal row, finding.field
      end

      test 'a switched-off row leaves a sensitive column on unconfigured_field_strategy' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        res = create_resource(permission_set: create_permission_set)
        create_resource_field(resource: res, name: 'email', read_access: false, is_active: false)
        assert_empty AttentionItems.new.privacy_findings, 'blocked by default'

        PermissionForge.configuration.unconfigured_field_strategy = :pass_through
        findings = AttentionItems.new.privacy_findings.index_by(&:name)
        assert_predicate findings['email'], :unconfigured?
        assert_predicate findings['email'], :turned_off?
        assert_not_predicate findings['email'], :implicit_grant?
        assert_predicate findings['name'], :unconfigured?
        assert_not_predicate findings['name'], :turned_off?
      end

      test 'without the implicit grant a sensitive virtual field follows unconfigured_field_strategy' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        create_resource(permission_set: create_permission_set)
        assert_empty AttentionItems.new.privacy_findings

        PermissionForge.configuration.unconfigured_field_strategy = :pass_through
        findings = AttentionItems.new.privacy_findings
        assert_equal %w[email full_address name], findings.map(&:name).sort
        assert findings.none?(&:implicit_grant?)
      end

      test 'muting sets and resources without Read give no implicit grant' do
        create_resource(permission_set: create_permission_set(name: 'Mute', is_muting: true), read_access: true)
        create_resource(permission_set: create_permission_set(name: 'Write only'), read_access: false)

        assert_empty AttentionItems.new.privacy_findings
      end

      test 'active rules are flagged while auto query scoping is off' do
        set = create_permission_set(name: 'Sales')
        res = create_resource(permission_set: set, read_access: true)
        create_permission_set_rule(permission_set: set, resource: res)
        create_permission_set_rule(permission_set: set, resource: res, name: 'Off', is_active: false)
        create_permission_set_user(user: create_user, permission_set: set)

        finding = AttentionItems.new.unenforced_rules.sole
        assert_equal [set, res, 1, 1], [finding.permission_set, finding.resource, finding.rule_count, finding.people_count]
      end

      test 'with auto query scoping on only join rules are flagged' do
        old = PermissionForge.configuration.auto_query_scoping
        PermissionForge.configuration.auto_query_scoping = :filter_only
        set = create_permission_set
        filtered = create_resource(permission_set: set, name: 'Customer', read_access: true)
        joined = create_resource(permission_set: set, name: 'Supplier', read_access: true)
        create_permission_set_rule(permission_set: set, resource: filtered)
        create_permission_set_rule(permission_set: set, resource: joined, join_type: 'joins', field_accessor_path: 'owner',
                                   field_name: 'id')

        assert_equal(['Supplier'], AttentionItems.new.unenforced_rules.map { |f| f.resource.name })
      ensure
        PermissionForge.configuration.auto_query_scoping = old
      end

      # Field test round 5 (d #49): the audit listed a typo'd Resource's rules
      # under rule/unenforced_rules as well as integrity/unknown_models.
      test 'rules of a Resource named after no model the app can load are not flagged' do
        typo = create_resource(permission_set: create_permission_set(name: 'Typo'), name: 'Custmer', read_access: true)
        create_permission_set_rule(permission_set: typo.permission_set, resource: typo)

        assert_empty AttentionItems.new.unenforced_rules
      end

      test 'rules bypassed by View All, on muting sets or on turned-off sets are not flagged' do
        bypassed = create_resource(permission_set: create_permission_set(name: 'All'), read_access: true, view_all: true)
        create_permission_set_rule(permission_set: bypassed.permission_set, resource: bypassed)
        inactive = create_resource(permission_set: create_permission_set(name: 'Off', is_active: false), read_access: true)
        create_permission_set_rule(permission_set: inactive.permission_set, resource: inactive)

        assert_empty AttentionItems.new.unenforced_rules
      end
    end

    class RuleFormTest < ActiveSupport::TestCase
      setup do
        @res = create_resource(permission_set: create_permission_set)
      end

      test 'builds filter rule attributes from sentence inputs' do
        form = RuleForm.new(resource: @res, params: { name: 'Mine', field_name: 'name', operator: 'in',
                                                      values_text: 'a, b', include_nulls: '1' })

        assert_predicate form, :valid?
        attrs = form.attributes
        assert_equal 'a,b', attrs[:field_value]
        assert_nil attrs[:join_type]
        assert attrs[:include_nulls]
      end

      test 'relationship rules get an automatic join type' do
        form = RuleForm.new(resource: @res, params: { name: 'Owner', path: ['supplier'], field_name: 'owner_id',
                                                      operator: 'equal', current_user: '1' })

        assert_predicate form, :valid?
        assert_equal 'supplier', form.attributes[:field_accessor_path]
        assert_equal 'joins', form.attributes[:join_type]
        assert_equal 'current_user', form.attributes[:field_value]
        assert_predicate form, :user_field?
      end

      test 'reports missing values per operator shape' do
        form = RuleForm.new(resource: @res, params: { name: 'x', field_name: 'name', operator: 'between', value_from: '1' })

        assert_not form.valid?
        assert_equal :range, form.errors[:value]
      end

      test 'loads an existing rule' do
        rule = create_permission_set_rule(permission_set: @res.permission_set, resource: @res)
        form = RuleForm.new(resource: @res, rule: rule)

        assert form.current_user
        assert_equal 'supplier_id', form.field_name
      end

      test 'virtual fields, declared or discovered, are never offered for rules' do
        PermissionForge.configuration.virtual_field_discovery = true
        res = create_resource(permission_set: @res.permission_set, name: 'PfVirtualAccount')
        options = RuleForm.new(resource: res, params: {}).field_options.map(&:name)

        assert_includes options, 'email'
        assert_empty options & %w[full_address nickname theme]
        %w[full_address theme].each do |name|
          form = RuleForm.new(resource: res, params: { name: 'Virtual', field_name: name, operator: 'equal', value: 'x' })
          assert_not form.valid?, name
          assert_equal :field, form.errors[:field]
        end
      end
    end

    class BulkPeopleMatcherTest < ActiveSupport::TestCase
      test 'matches emails and names exactly and reports the rest' do
        set = create_permission_set
        ana = create_user(name: 'Ana Krasniqi', email: 'ana@acme.test')
        bo = create_user(name: 'Bo', email: 'bo@acme.test')
        create_permission_set_user(user: bo, permission_set: set)

        result = BulkPeopleMatcher.new.call(text: "ANA@acme.test\nBo, nobody@x.test", user_ids: [], permission_set: set)

        assert_equal [ana], result.to_assign
        assert_equal [bo], result.already
        assert_equal ['nobody@x.test'], result.not_found
      end
    end

    class ModelCatalogTest < ActiveSupport::TestCase
      include VirtualFieldTestSupport

      test 'lists app models with columns, associations and virtual fields' do
        catalog = ModelCatalog.new
        customer = catalog.find('Customer')

        assert_includes catalog.models.map(&:name), 'Customer'
        assert_not_includes customer.managed_column_names, 'id'
        assert_includes customer.virtual_field_names, 'full_address'
        assert_equal 'Supplier', customer.association('supplier').class_name
        assert catalog.find('Supplier').column('owner_id').user_reference?
        assert_nil catalog.find('PermissionForge::PermissionSet')
      end

      test 'honors admin_model_resolver' do
        PermissionForge.configuration.admin_model_resolver = -> { [Supplier] }

        assert_equal ['Supplier'], ModelCatalog.new.models.map(&:name)
      end

      test 'virtual fields: declared ones always, discovered ones only while discovery is on' do
        model = ModelCatalog.new.find('PfVirtualAccount')

        assert_equal %w[full_address], model.declared_virtual_field_names
        assert_equal %w[full_address], model.virtual_field_names
        assert_equal model.managed_column_names + %w[full_address], model.managed_field_names

        PermissionForge.configuration.virtual_field_discovery = true
        model = ModelCatalog.new.find('PfVirtualAccount')

        assert_equal %w[full_address], model.declared_virtual_field_names
        assert_equal %w[full_address nickname theme], model.virtual_field_names
        assert_equal %w[full_address nickname theme], model.columns.select(&:virtual?).map(&:name)
      end

      test 'virtual field names never include a column or an ignored field' do
        PermissionForge.configuration.virtual_field_discovery = true
        with_extra_fields(::PfVirtualAccount, %w[email full_address uuid shipping_note]) do
          model = ModelCatalog.new.find('PfVirtualAccount')

          assert_equal %w[full_address shipping_note], model.declared_virtual_field_names
          assert_not_includes model.managed_field_names, 'uuid'
          assert_equal 1, model.managed_field_names.count('email')
        end
      end

      test 'implicit_grant? follows the declared list and extra_fields_default_access' do
        PermissionForge.configuration.virtual_field_discovery = true
        with_extra_fields(::PfVirtualAccount, %i[full_address email]) do
          model = ModelCatalog.new.find('PfVirtualAccount')

          assert model.implicit_grant?('full_address')
          assert model.implicit_grant?(:email), 'a declared name that is a column is granted by the engine too'
          assert_not model.implicit_grant?('nickname'), 'discovered names are never granted'
          assert_not model.implicit_grant?('domain')

          PermissionForge.configuration.extra_fields_default_access = :unconfigured
          assert_not model.implicit_grant?('full_address')
        end
      end

      test 'virtual_field? recognises a discoverable name even while discovery is off' do
        model = ModelCatalog.new.find('PfVirtualAccount')

        assert model.virtual_field?('theme')
        assert model.virtual_field?('full_address')
        assert_not model.virtual_field?('email')
        assert_not model.virtual_field?('legacy_col')
      end

      test 'masked_on_model? needs a wrapped reader and a configuration that selects the model' do
        model = ModelCatalog.new.find('PfVirtualProfile')
        ::PfVirtualProfile.pf_mask_virtual_readers(%w[display_name])
        assert_not model.masked_on_model?('display_name'), 'mask_virtual_attributes is off'

        PermissionForge.configuration.mask_virtual_attributes = :auto
        assert model.masked_on_model?('display_name')
        assert_not model.masked_on_model?('missing_reader'), 'declared, but there is no reader to wrap'
      end

      test 'a model whose extra fields method raises has no declared virtual fields, and the log says why' do
        with_extra_fields(::PfVirtualAccount, -> { raise 'boom' }) do
          model = ModelCatalog.new.find('PfVirtualAccount')
          log = captured_log { assert_empty model.declared_virtual_field_names }

          assert_match(/PfVirtualAccount\.extra_fields_for_permissions raised RuntimeError: boom/, log)
          assert_not model.implicit_grant?('full_address')
        end
      end
    end

    class FieldRowsTest < ActiveSupport::TestCase
      test 'merges configured fields, new columns and missing columns' do
        res = create_resource(permission_set: create_permission_set)
        create_resource_field(resource: res, name: 'name')
        create_resource_field(resource: res, name: 'legacy_col')
        rows = FieldRows.new(res)

        assert_includes rows.new_columns, 'email'
        assert_equal ['legacy_col'], rows.missing_fields.map(&:name)
        assert_predicate rows, :sync_needed?
        assert_equal 'read', rows.row('name').level
        assert rows.counts['unconfigured'].positive?
      end

      test 'unconfigured virtual fields are new columns and say what applies right now' do
        res = create_resource(permission_set: create_permission_set, name: 'PfVirtualAccount')
        create_resource_field(resource: res, name: 'name')
        PermissionForge.configuration.virtual_field_discovery = true
        rows = FieldRows.new(res)

        assert_includes rows.new_columns, 'full_address'
        assert_includes rows.new_columns, 'theme'
        declared = rows.row('full_address')
        assert_equal [true, true, true, false], [declared.virtual, declared.declared, declared.implicit_grant, declared.missing]
        discovered = rows.row('theme')
        assert_equal [true, false, false], [discovered.virtual, discovered.declared, discovered.implicit_grant]
        assert_equal [false, false, false], rows.row('email').to_h.values_at(:virtual, :declared, :implicit_grant)
        assert_not rows.row('name').implicit_grant

        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        assert_not FieldRows.new(res).row('full_address').implicit_grant
      end

      test 'a configured virtual field is never implicit and never reported as a missing column' do
        res = create_resource(permission_set: create_permission_set, name: 'PfVirtualAccount')
        create_resource_field(resource: res, name: 'full_address', read_access: false)
        create_resource_field(resource: res, name: 'theme')
        rows = FieldRows.new(res)

        assert_not rows.row('full_address').implicit_grant
        assert_predicate rows.row('full_address'), :in_force?
        assert rows.row('full_address').virtual
        assert rows.row('theme').virtual, 'configured while discovery was on, discovery now off'
        assert_empty rows.missing_fields
        assert_not_includes rows.new_columns, 'full_address'
      end

      test 'a switched-off row of a declared virtual field is on the implicit grant, and stays one row' do
        res = create_resource(permission_set: create_permission_set, name: 'PfVirtualAccount')
        create_resource_field(resource: res, name: 'full_address', read_access: false, is_active: false)
        create_resource_field(resource: res, name: 'email', read_access: false, is_active: false)
        rows = FieldRows.new(res)
        off = rows.row('full_address')

        assert_equal [true, false, true, 'hidden'], [off.configured?, off.in_force?, off.implicit_grant, off.level]
        assert_equal(1, rows.rows.count { |row| row.name == 'full_address' })
        assert_not_includes rows.new_columns, 'full_address'
        assert_equal [true, false, false], [rows.row('email').configured?, rows.row('email').in_force?, rows.row('email').implicit_grant]
        assert_equal [false, false], [rows.row('name').configured?, rows.row('name').in_force?], 'no row at all'

        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        assert_not FieldRows.new(res).row('full_address').implicit_grant
      end
    end
  end
end
