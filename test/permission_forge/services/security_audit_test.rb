require 'test_helper'

module PermissionForge
  module Services
    # rake permission_forge:audit — read-only findings about configuration,
    # privileges, assignments, rules, integrity and personal data.
    class SecurityAuditTest < ActiveSupport::TestCase
      setup do
        @config = PermissionForge::Configuration.new
        @config.user_class = 'User'
        @config.unconfigured_field_strategy = :block
        @config.gdpr_defaults = true
      end

      def audit(environment: 'test', **overrides)
        overrides.each { |key, value| @config.public_send("#{key}=", value) }
        SecurityAudit.call(configuration: @config, environment: environment)
      end

      def codes(report) = report.findings.map(&:code)

      # A model whose table does not exist.
      class Tableless < ActiveRecord::Base
        self.table_name = 'pf_audit_no_such_table'
      end

      # A rule as the table can hold it, whatever the validations say today.
      def rule_with(resource, **attrs)
        rule = create_permission_set_rule(permission_set: resource.permission_set, resource: resource, include_nulls: false)
        rule.update_columns(attrs)
        rule
      end

      def item_for(report, code) = report.findings.find { |f| f.code == code }

      test 'a default install gets notes (nil-user bypass, unused record rules, audit log defaults) and one medium' do
        report = audit(audit_actor_resolver: ->(_controller) {})

        assert_equal %i[masked_nil_user_bypass nil_user_bypass no_rules audit_runtime_default audit_kept_forever], codes(report)
        assert_equal %i[masked_nil_user_bypass], report.at_least(:medium).map(&:code)

        hardened = audit(audit_actor_resolver: ->(_controller) {}, masked_attributes_nil_user_strategy: :hide)
        assert_empty hardened.at_least(:medium)
      end

      test 'action rows that share a name on one resource are reported' do
        resource = create_resource(permission_set: create_permission_set(name: 'Sales'), name: 'Customer', read_access: true)
        create_resource_action(resource: resource, name: 'export', is_permitted: false)
        assert_not_includes codes(audit), :duplicate_actions

        PermissionForge::ResourceAction.new(uuid: SecureRandom.uuid, resource: resource, name: 'export',
                                            is_permitted: true).save!(validate: false)
        finding = item_for(audit, :duplicate_actions)

        assert_equal :medium, finding.severity
        assert_equal ['Sales › Customer.export: 2 rows'], finding.items
      end

      test 'an admin UI with no authentication is critical' do
        report = audit(http_basic_auth_enabled: false)

        assert_equal :critical, item_for(report, :admin_ui_exposed).severity
        assert_not_includes codes(audit(http_basic_auth_enabled: false, base_controller_class: '::AdminController')),
                            :admin_ui_exposed
      end

      test 'a process-local cache is flagged only in production' do
        assert_includes codes(audit(environment: 'production', cache_backend: :memory)), :process_local_cache
        assert_not_includes codes(audit(cache_backend: :memory)), :process_local_cache
      end

      test 'fail-open flags are flagged' do
        report = audit(unconfigured_field_strategy: :pass_through, masked_write_protection: :off,
                       nil_user_strategy: :bypass, gdpr_defaults: false, audit_trail_enabled: false)

        assert_equal %i[high high], report.findings.select { |f| %i[unconfigured_fields_pass write_protection_off].include?(f.code) }
                                          .map(&:severity)
        assert_includes codes(report), :nil_user_bypass
        assert_includes codes(report), :gdpr_defaults_off
        assert_includes codes(report), :audit_trail_off
      end

      # The parent fallback is a fail-open knob: a key editable on the parent
      # admits the same key on a child the user was never granted.
      test 'the nested-attributes parent fallback is flagged' do
        assert_not_includes codes(audit), :nested_parent_fallback

        finding = item_for(audit(nested_attributes_parent_fallback: true), :nested_parent_fallback)
        assert_equal :medium, finding.severity
        assert_includes finding.detail, 'nested_attributes_parent_fallback'
      end

      test 'an enabled API without authorization lambdas is high once requiring them is switched off' do
        report = audit(api_enabled: true, api_auth: ->(_c) { true }, api_record_identifier: :id,
                       api_require_authorization: false)

        assert_equal :high, item_for(report, :api_mutations_unguarded).severity
        assert_includes codes(report), :api_sequential_ids
        assert_not_includes codes(audit(api_enabled: true, api_auth: ->(_c) { true }, api_require_authorization: true)),
                            :api_mutations_unguarded
        assert_not_includes codes(audit(api_enabled: true, api_auth: ->(_c) { true })), :api_mutations_unguarded
      end

      test 'conditional sets are flagged while strict mode is off' do
        create_permission_set(name: 'Office only', allowed_ips: '10.0.0.0/8')

        assert_equal ['Office only'], item_for(audit, :conditional_sets_lenient).items
        assert_not_includes codes(audit(conditional_sets_strict_mode: true)), :conditional_sets_lenient
      end

      test 'privileged and temporary-looking sets held by people' do
        set = create_permission_set(name: 'Dev full access')
        create_resource(permission_set: set, name: 'Customer', read_access: true, view_all: true)
        create_permission_set_user(user: create_user, permission_set: set)

        report = audit
        assert_equal ['Dev full access › Customer: View All · 1 person'], item_for(report, :bypass_grants).items
        assert_equal :medium, item_for(report, :temporary_sets).severity
      end

      test 'unenforced rules held by people are high, and name the fix' do
        set = create_permission_set(name: 'Sales')
        resource = create_resource(permission_set: set, read_access: true)
        create_permission_set_rule(permission_set: set, resource: resource)
        create_permission_set_user(user: create_user, permission_set: set)

        finding = item_for(audit, :unenforced_rules)
        assert_equal :high, finding.severity
        assert_equal ['Sales › Customer: 1 rule(s) · 1 person'], finding.items
        assert_match 'auto_query_scoping', finding.detail
        assert_not_includes codes(audit), :no_rules
      end

      test 'rules whose value the column cannot hold are reported as matching nothing' do
        set = create_permission_set(name: 'Sales')
        resource = create_resource(permission_set: set, read_access: true)
        create_permission_set_user(user: create_user, permission_set: set)
        through_owner = { join_type: 'joins', field_accessor_path: 'supplier.owner' }
        rule_with(resource, name: 'Own', field_name: 'supplier_id', operator: 'equal', field_value: '5_id')
        rule_with(resource, name: 'Some', field_name: 'customers.supplier_id', operator: 'not_in', field_value: '5, x')
        rule_with(resource, name: 'Range', field_name: 'supplier_id', operator: 'between', field_value: '1,2,3')
        rule_with(resource, name: 'Active owner', field_name: 'users.deactivated', field_value: 'maybe', **through_owner)
        rule_with(resource, name: 'Me', field_name: 'deactivated', field_value: 'current_user', **through_owner)
        rule_with(resource, name: 'Mine', field_name: 'supplier_id', field_value: 'current_user')
        rule_with(resource, name: 'Few', field_name: 'supplier_id', operator: 'less_than', field_value: '5.5')
        rule_with(resource, name: 'Ours', field_name: 'domain', operator: 'in', field_value: 'a.com, current_user')
        rule_with(resource, name: 'Off', field_name: 'owner_id', field_value: 'no', **through_owner.merge(field_accessor_path: 'supplier'))
        rule_with(resource, name: 'Dot', field_name: 'supplier_id.', field_value: '5')
        rule_with(resource, name: 'Case', field_name: 'Supplier_ID', field_value: '5_id')

        finding = item_for(audit, :unusable_rule_values)
        # MySQL and SQLite resolve the name in any case, so the rule is typed and matches nothing there.
        case_item = ActiveRecord::Base.connection.adapter_name == 'PostgreSQL' ? [] : ['Sales › Customer.Supplier_ID equal "5_id": Case · 1 person']

        assert_equal :medium, finding.severity
        assert_equal 'rule', finding.check
        assert_match 'matches nothing', finding.detail
        assert_equal ['Sales › Customer.supplier_id equal "5_id": Own · 1 person',
                      'Sales › Customer.customers.supplier_id not_in "5, x": Some · 1 person',
                      'Sales › Customer.supplier_id between "1,2,3": Range · 1 person',
                      'Sales › Customer.supplier.owner.users.deactivated equal "maybe": Active owner · 1 person',
                      'Sales › Customer.supplier.owner.deactivated equal "current_user": Me · 1 person',
                      'Sales › Customer.supplier.owner_id equal "no": Off · 1 person',
                      'Sales › Customer.supplier_id. equal "5": Dot · 1 person',
                      *case_item], finding.items
      end

      test 'a rule that is not in effect, or held by nobody, weighs less' do
        sales = create_permission_set(name: 'Sales')
        rule_with(create_resource(permission_set: sales, read_access: true), name: 'Own', field_name: 'supplier_id', field_value: 'x')

        finding = item_for(audit, :unusable_rule_values)

        assert_equal :low, finding.severity
        assert_equal ['Sales › Customer.supplier_id equal "x": Own · 0 people'], finding.items

        off = create_permission_set(name: 'Off', is_active: false)
        muting = create_permission_set(name: 'Muting', is_muting: true)
        parked = create_resource(permission_set: create_permission_set(name: 'Parked'), read_access: true, is_active: false)
        [create_resource(permission_set: off, read_access: true), create_resource(permission_set: muting), parked].each do |resource|
          rule_with(resource, name: 'Not applied', field_name: 'supplier_id', field_value: 'x')
        end
        rule_with(sales.resources.first, name: 'Switched off', field_name: 'supplier_id', field_value: 'x', is_active: false)

        assert_equal 1, item_for(audit, :unusable_rule_values).items.size
      end

      test 'a rule View All skips denies nobody: it is a bypassed rule, not one that matches nothing' do
        set = create_permission_set(name: 'Managers')
        resource = create_resource(permission_set: set, read_access: true, view_all: true)
        create_permission_set_user(user: create_user, permission_set: set)
        rule_with(resource, name: 'Own', field_name: 'supplier_id', field_value: '5_id')

        report = audit

        assert_not_includes codes(report), :unusable_rule_values
        assert_equal ['Managers › Customer: Own'], item_for(report, :bypassed_rules).items

        resource.update_columns(view_all: false)

        assert_equal ['Managers › Customer.supplier_id equal "5_id": Own · 1 person'], item_for(audit, :unusable_rule_values).items
      end

      test 'a rule whose model, association or column cannot be found is no finding and no error' do
        set = create_permission_set(name: 'Legacy')
        gone = create_resource(permission_set: set, name: 'Supplier', read_access: true)
        resource = create_resource(permission_set: set, read_access: true)
        rule_with(gone, name: 'Gone', field_name: 'owner_id', field_value: 'x')
        rule_with(resource, name: 'No column', field_name: 'no_such_column', field_value: 'x')
        rule_with(resource, name: 'Elsewhere', field_name: 'elsewhere.supplier_id', field_value: 'x')
        # The engine raises for a path it cannot follow; the rule is not typed against its own model.
        rule_with(resource, name: 'No path', field_name: 'supplier_id', field_value: 'x', join_type: 'joins', field_accessor_path: 'nowhere')
        rule_with(resource, name: 'Half a path', field_name: 'deactivated', field_value: 'maybe', join_type: 'left_joins',
                            field_accessor_path: 'supplier.nowhere')
        gone.update_columns(name: 'FreightCost')

        report = audit

        assert_not_includes codes(report), :unusable_rule_values
        assert_includes item_for(report, :unknown_models).items, 'FreightCost'
      end

      # Only the rule check runs here: asked for the columns of a missing
      # table, PostgreSQL fails the statement and the test's transaction with it.
      test 'a rule on a model whose table is missing is no finding and no error' do
        resource = create_resource(permission_set: create_permission_set(name: 'Legacy'), name: 'Supplier', read_access: true)
        rule_with(resource, name: 'No table', field_name: 'id', field_value: 'x')
        rule_with(resource, name: 'No list', field_name: 'id', operator: 'in', field_value: '')
        resource.update_columns(name: Tableless.name)

        report = SecurityAudit.call(configuration: @config, checks: [SecurityAuditChecks::RuleCheck], environment: 'test')

        assert_not_includes codes(report), :unusable_rule_values
        assert_equal 1, PermissionForge::PermissionSetRule.where(name: 'No table').count, 'the transaction is still usable'
      end

      test 'a date that is not ISO 8601 matches nothing on MySQL and SQLite, and is left to PostgreSQL' do
        resource = create_resource(permission_set: create_permission_set(name: 'Sales'), read_access: true)
        rule_with(resource, name: 'Recent', field_name: 'created_at', operator: 'greater_than', field_value: 'yesterday')
        rule_with(resource, name: 'This year', field_name: 'created_at', operator: 'greater_than', field_value: '2026-01-01')

        if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
          assert_not_includes codes(audit), :unusable_rule_values
        else
          assert_equal ['Sales › Customer.created_at greater_than "yesterday": Recent · 0 people'],
                       item_for(audit, :unusable_rule_values).items
        end
      end

      test 'stale, missing-user and deactivated-user assignments' do
        set = create_permission_set(name: 'Support')
        stale = create_permission_set_user(user: create_user(name: 'Ana Krasniqi'), permission_set: set)
        stale.update_columns(created_at: 200.days.ago)
        create_permission_set_user(user: create_user(name: 'Gone'), permission_set: set).tap do |row|
          row.update_columns(user_id: 999_999)
        end
        create_permission_set_user(user: create_user(name: 'Bo Berisha', deactivated: true), permission_set: set)

        report = audit(user_active_check: ->(user) { !user.deactivated })
        assert_match 'Ana Krasniqi — Support', item_for(report, :stale_assignments).items.sole
        assert_equal ['User #999999'], item_for(report, :missing_users).items
        assert_equal ['Bo Berisha'], item_for(report, :inactive_users).items
        assert_includes codes(report), :all_permanent
      end

      test 'integrity: dependency violations and resources for unknown models' do
        set = create_permission_set(name: 'Legacy')
        resource = create_resource(permission_set: set, read_access: true)
        resource.update_columns(read_access: false, edit_access: true)
        create_resource(permission_set: set, name: 'Freight', read_access: true).update_columns(name: 'FreightCost')

        report = audit
        assert_equal ['Legacy › Customer: edit without read'], item_for(report, :dependency_violations).items
        assert_equal ['FreightCost'], item_for(report, :unknown_models).items
      end

      test 'personal data unmasked, unless marked intended' do
        resource = create_resource(permission_set: create_permission_set(name: 'Sales'), read_access: true)
        field = create_resource_field(resource: resource, name: 'email', read_access: true, mask_access: false)

        assert_match 'Sales › Customer.email', item_for(audit, :unmasked_personal_data).items.sole

        field.update_columns(sensitive_acknowledged_at: Time.current)
        assert_not_includes codes(audit), :unmasked_personal_data
      end

      test 'personal data in a virtual field left on the implicit grant' do
        resource = create_resource(permission_set: create_permission_set(name: 'Sales'), read_access: true)
        finding = item_for(audit, :implicit_virtual_personal_data)

        assert_equal :medium, finding.severity
        assert_equal ['Sales › Customer.full_address (suggested: full)'], finding.items

        create_resource_field(resource: resource, name: 'full_address', read_access: true, mask_access: true)
        assert_not_includes codes(audit), :implicit_virtual_personal_data
      end

      test 'under :unconfigured a sensitive virtual field is unmapped personal data instead' do
        create_resource(permission_set: create_permission_set(name: 'Sales'), read_access: true)
        report = audit(extra_fields_default_access: :unconfigured)

        assert_not_includes codes(report), :implicit_virtual_personal_data
        assert_includes item_for(report, :unmapped_personal_data).items, 'Customer.full_address'
        assert_equal :low, item_for(report, :unmapped_personal_data).severity
      end

      test 'report counts, threshold filtering and renderings' do
        report = audit(http_basic_auth_enabled: false)

        assert_equal 1, report.counts[:critical]
        assert_equal %i[admin_ui_exposed], report.at_least(:high).map(&:code)
        assert_equal :admin_ui_exposed, report.to_h[:findings].first[:code]

        text = SecurityAuditChecks::TextReport.new(report).to_s
        assert_match '[CRITICAL] The admin UI has no authentication', text
        assert_match 'Read-only: nothing was changed', text
      end
    end
  end
end
