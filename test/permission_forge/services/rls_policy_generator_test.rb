require 'test_helper'

module PermissionForge
  module Services
    # SQL-text tests for RLS policy generation — run on any adapter (the
    # service only builds strings). End-to-end enforcement lives in test/rls/.
    class RlsPolicyGeneratorTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(permission_set: @permission_set, name: 'Customer')
      end

      test 'emits enable, force, drop, four policies and a digest comment' do
        result = RlsPolicyGenerator.call(model_class: Customer)
        statements = result[:statements]

        assert_equal 'customers', result[:table]
        assert(statements.any? { |s| s.include?('ENABLE ROW LEVEL SECURITY') })
        assert(statements.any? { |s| s.include?('FORCE ROW LEVEL SECURITY') })
        assert_equal(4, statements.count { |s| s.start_with?('DROP POLICY IF EXISTS') })
        assert(statements.any? { |s| s.include?('CREATE POLICY permission_forge_select') && s.include?('FOR SELECT') })
        assert(statements.any? { |s| s.include?('permission_forge_insert') && s.include?('WITH CHECK (true)') })
        assert(statements.any? { |s| s.include?('permission_forge_update') && s.include?('FOR UPDATE') })
        assert(statements.any? { |s| s.include?('permission_forge_delete') && s.include?('FOR DELETE') })
        assert(statements.any? { |s| s.include?('COMMENT ON POLICY permission_forge_select') })
      end

      test 'current_user rules translate to the session variable with a quoted column' do
        add_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        using = select_policy_sql

        assert_includes using, "current_setting('permission_forge.user_id', true)"
        assert_includes using, "#{quoted_column('supplier_id')} ="
      end

      test 'include_nulls adds an IS NULL alternative' do
        add_rule(operator: 'equal', field_value: 'current_user', include_nulls: true)

        assert_includes select_policy_sql, "#{quoted_column('supplier_id')} IS NULL"
      end

      test 'in operator translates to a quoted IN list' do
        add_rule(operator: 'in', field_name: 'domain', field_value: 'a.com, b.com', include_nulls: false)

        assert_includes select_policy_sql, %(#{quoted_column('domain')} IN ('a.com', 'b.com'))
      end

      test 'contains operator translates to an escaped ILIKE' do
        add_rule(operator: 'contains', field_name: 'name', field_value: '50%_off', include_nulls: false)
        using = select_policy_sql

        assert_includes using, "ILIKE #{Customer.connection.quote('%50\\%\\_off%')} ESCAPE"
      end

      test 'membership is checked dynamically per permission set' do
        add_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        using = select_policy_sql

        assert_includes using, "psu.permission_set_id = #{@permission_set.id}"
        assert_includes using, 'psu.expires_at IS NULL OR psu.expires_at >= now()'
        assert_includes using, 'NOT EXISTS'
      end

      test 'view_all bypass branch checks granting and muting sets' do
        using = select_policy_sql

        assert_includes using, 'r.view_all = TRUE OR r.modify_all = TRUE'
        assert_includes using, 'ps.is_muting = TRUE'
        assert_includes using, 'ps.is_muting = FALSE'
      end

      # Pre-release review core-security #6: the EXISTS ignored
      # Resource.is_active, so deactivating a view_all row stopped the app
      # layer's bypass and not the policy's; and it had no tenant predicate,
      # so a view_all grant in one tenant bypassed the rules on every
      # tenant's rows.
      test 'the view_all bypass requires the resource row to be active, granting and muting alike' do
        assert_equal 2, select_policy_sql.scan('r.is_active = TRUE').size
      end

      test 'with tenancy on and a tenant column on the table, the bypass is tied to the row tenant' do
        predicate = "r.#{Customer.connection.quote_column_name('account_id')} = #{quoted_column('account_id')}"

        assert_equal 2, select_policy_sql.scan(predicate).size
      end

      test 'without tenancy, or without a tenant column on the protected table, there is no tenant predicate' do
        require_relative '../rule_value_models'
        no_column = RlsPolicyGenerator.call(model_class: PfRuleRecord)[:statements].join(' ')

        assert_not_includes no_column, 'account_id'
        assert_includes no_column, 'r.is_active = TRUE'

        PermissionForge.configuration.tenant_model = nil
        assert_not_includes select_policy_sql, 'account_id'
      end

      test 'the digest changes with the tenant predicate' do
        with_tenancy = RlsPolicyGenerator.call(model_class: Customer)[:digest]
        PermissionForge.configuration.tenant_model = nil

        assert_not_equal with_tenancy, RlsPolicyGenerator.call(model_class: Customer)[:digest]
      end

      # The rules of a resource row are compiled whatever its is_active, and
      # the membership EXISTS checks the row's state per statement: switching
      # a resource off or on is live without a re-sync, never wider than the
      # app layer in between (review MINOR-1).
      test 'the rules of a switched-off resource are compiled, with the row state checked in the membership EXISTS' do
        add_rule(operator: 'equal', field_name: 'domain', field_value: 'gone.com', include_nulls: false)
        @resource.update!(is_active: false)
        using = select_policy_sql

        assert_includes using, 'gone.com'
        assert_includes using, "r.id = #{@resource.id}"
        assert_equal 3, using.scan('r.is_active = TRUE').size, 'the two view_all EXISTS and the membership EXISTS'
        assert_equal RlsPolicyGenerator.call(model_class: Customer)[:digest],
                     RlsPolicyGenerator.call(model_class: Customer).tap { @resource.update!(is_active: true) }[:digest],
                     'no re-sync for a state the policy reads live'
      end

      # The app layer applies them to the subclass (ResourceChain); a policy
      # is per table, so they hold at the application layer only — and are
      # reported, never silently left out.
      test 'rules on a Resource named after an STI subclass are reported as skipped' do
        require_relative '../sti_models'
        subclass = create_resource(permission_set: @permission_set, name: 'PfStiBugTicket')
        create_permission_set_rule(permission_set: @permission_set, resource: subclass, name: 'Open only', field_name: 'status',
                                   operator: 'equal', field_value: 'open')
        off = create_resource(permission_set: @permission_set, name: 'PfStiUrgentBugTicket', is_active: false)
        create_permission_set_rule(permission_set: @permission_set, resource: off, name: 'Off', field_name: 'status',
                                   operator: 'equal', field_value: 'x')
        other_table = create_resource(permission_set: @permission_set, name: 'PfStiArchivedTicket')
        create_permission_set_rule(permission_set: @permission_set, resource: other_table, name: 'Archived', field_name: 'title',
                                   operator: 'equal', field_value: 'x')
        result = RlsPolicyGenerator.call(model_class: PfStiTicket)

        assert_equal [{ permission_set: @permission_set.name, rule: 'Open only', reason: :sti_subclass_resource }], result[:skipped_rules]
        assert_not_includes result[:statements].join(' '), 'open'
        assert_empty RlsPolicyGenerator.call(model_class: PfStiBugTicket)[:skipped_rules], 'asked for the subclass itself: compiled'
      end

      test 'only unconditional sets grant the view_all bypass (consent guard)' do
        using = select_policy_sql

        # The granting EXISTS must require the set to have no activation
        # conditions — a consent/IP/hours-gated set granting view_all must
        # never widen DB-level access while its condition is unmet. "No
        # condition" has one definition, PermissionSet.unconditional's: a
        # text of blanks is none, one hour of the two is one.
        assert_includes using, "NOT #{PermissionSet.conditions_present_sql(table: 'ps')}"
        assert_includes using, "ps.#{Customer.connection.quote_column_name('allowed_hours_end')} IS NOT NULL"
        assert_includes using, 'TRIM('
      end

      test 'an assignment ending now still counts, as PermissionSetUser.active_assignments counts it' do
        add_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)

        assert_includes select_policy_sql, 'psu.expires_at >= now()'
        assert_not_includes select_policy_sql, 'psu.expires_at > now()'
        travel_to(Time.current.change(usec: 0)) do
          create_permission_set_user(user: create_user, permission_set: @permission_set, expires_at: Time.current)

          assert_equal 2, PermissionSetUser.active_assignments.where(permission_set: @permission_set).count, 'inclusive in Ruby'
        end
      end

      test 'the generator version names the policies of this release' do
        assert_equal 7, RlsPolicyGenerator::GENERATOR_VERSION
      end

      test 'nil_user_strategy :bypass allows a missing session variable' do
        PermissionForge.configuration.nil_user_strategy = :bypass

        assert_includes select_policy_sql, 'IS NULL OR'
      end

      test 'nil_user_strategy :deny hides rows when the session variable is missing' do
        PermissionForge.configuration.nil_user_strategy = :deny

        assert_includes select_policy_sql, 'IS NOT NULL AND'
      end

      # A muting set contributes no rules. An inactive set's rules are
      # compiled behind the membership EXISTS's live `ps.is_active` check, so
      # switching a set off or on is never wider than the app layer until a
      # re-sync (review round 2, MINOR-R2-1).
      test 'muting sets contribute no rules; an inactive set is compiled behind the live set check' do
        muting_set = create_permission_set(name: 'Muting', is_muting: true)
        muting_resource = create_resource(permission_set: muting_set, name: 'Customer')
        create_permission_set_rule(permission_set: muting_set, resource: muting_resource,
                                   field_name: 'domain', field_value: 'muted.com', operator: 'equal')

        inactive_set = create_permission_set(name: 'Inactive', is_active: false)
        inactive_resource = create_resource(permission_set: inactive_set, name: 'Customer')
        create_permission_set_rule(permission_set: inactive_set, resource: inactive_resource,
                                   field_name: 'domain', field_value: 'inactive.com', operator: 'equal')

        using = select_policy_sql
        refute_includes using, 'muted.com'
        assert_includes using, 'inactive.com'
        assert_includes using, "psu.permission_set_id = #{inactive_set.id}"
        assert_equal RlsPolicyGenerator.call(model_class: Customer)[:digest],
                     RlsPolicyGenerator.call(model_class: Customer).tap { inactive_set.update!(is_active: true) }[:digest],
                     'no re-sync for a state the policy reads live'
      end

      test 'join rules and dotted field names are reported as skipped, never silently dropped' do
        add_rule(operator: 'equal', field_name: 'owner_id', field_value: 'current_user',
                 join_type: 'joins', field_accessor_path: 'supplier', include_nulls: false)
        result = RlsPolicyGenerator.call(model_class: Customer)

        assert_equal 1, result[:skipped_rules].size
        assert_equal :join_rule, result[:skipped_rules].first[:reason]
        refute_includes result[:statements].join(' '), 'owner_id'
      end

      test 'a rule whose join_type says filter is a filter rule to the policy too' do
        rule = add_rule(operator: 'equal', field_name: 'domain', field_value: 'a.com', include_nulls: false)
        rule.update_columns(join_type: 'filter')
        result = RlsPolicyGenerator.call(model_class: Customer)

        assert_empty result[:skipped_rules]
        assert_includes result[:statements].join(' '), "#{quoted_column('domain')} = 'a.com'"
      end

      test 'no translatable rules produces a TRUE rules branch' do
        assert_includes select_policy_sql, 'TRUE'
      end

      test 'digest changes when rule content changes' do
        rule = add_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        before = RlsPolicyGenerator.call(model_class: Customer)[:digest]

        rule.update!(field_value: '42')
        after = RlsPolicyGenerator.call(model_class: Customer)[:digest]

        refute_equal before, after
      end

      test 'digest is stable for identical state' do
        add_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)

        assert_equal RlsPolicyGenerator.call(model_class: Customer)[:digest],
                     RlsPolicyGenerator.call(model_class: Customer)[:digest]
      end

      private

      # The generator quotes with the live connection; only PostgreSQL runs the
      # result, but the text is built on any adapter.
      def quoted_column(name)
        connection = Customer.connection
        "#{connection.quote_table_name('customers')}.#{connection.quote_column_name(name)}"
      end

      def add_rule(**attrs)
        create_permission_set_rule(permission_set: @permission_set, resource: @resource, **attrs)
      end

      def select_policy_sql
        RlsPolicyGenerator.call(model_class: Customer)[:statements]
                          .find { |s| s.include?('CREATE POLICY permission_forge_select') }
      end
    end
  end
end
