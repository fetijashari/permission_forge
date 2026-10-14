# frozen_string_literal: true

require_relative '../rule_value_models'

module PermissionForge
  module Services
    # What a rule compiles to in an RLS policy: the value typed the way the
    # application layer types it. SQL-text tests, on any adapter — the rows a
    # policy selects are compared with the application layer's in
    # test/rls/rls_rule_parity_test.rb.
    class RlsOperatorSqlTest < ActiveSupport::TestCase
      UID = "NULLIF(current_setting('permission_forge.user_id', true), '')"

      setup do
        @permission_set = create_permission_set
        @resource = create_resource(permission_set: @permission_set, name: 'PfRuleRecord')
      end

      test 'a value is written as a literal of the column type' do
        assert_equal "(#{col('small_count')} < 5.5)", compiled('small_count', 'less_than', '5.5')
        assert_equal "(#{col('small_count')} = 5)", compiled('small_count', 'equal', ' +5 ')
        assert_equal "(#{col('owner_id')} <> 99999999999999999999.0)", compiled('owner_id', 'not_equal', '99999999999999999999')
        assert_equal "(#{col('flag')} = #{quote(true)})", compiled('flag', 'equal', 'Yes')
        assert_equal "(#{col('flag')} <> #{quote(false)})", compiled('flag', 'not_equal', 'off')
        assert_equal "(#{col('label')} = '5')", compiled('label', 'equal', '5')
        assert_equal "(#{col('born_on')} >= '2026-01-10')", compiled('born_on', 'greater_than_or_equal', '2026-01-10T18:30')
        assert_equal "(#{col('seen_at')} > '2026-01-10 10:00:00')", compiled('seen_at', 'greater_than', '2026-01-10 12:00:00+02:00')
      end

      test 'an enum label is written as the value the model stores' do
        assert_equal "(#{col('status')} = 1)", compiled('status', 'equal', 'archived')
        assert_equal "(#{col('status')} IN (0, 2))", compiled('status', 'in', 'active, hidden')
        assert_equal "(#{col('tier')} <> 'G')", compiled('tier', 'not_equal', 'gold')
      end

      test 'lists and ranges are typed element by element' do
        assert_equal "(#{col('small_count')} IN (5, 0, 1.5))", compiled('small_count', 'in', '5, 0, 1.5')
        assert_equal "(#{col('label')} NOT IN ('a', 'current_user'))", compiled('label', 'not_in', 'a, current_user')
        assert_equal "(#{col('small_count')} BETWEEN 0 AND 5.5)", compiled('small_count', 'between', '0,5.5')
        assert_equal "(#{col('born_on')} BETWEEN '2025-01-01' AND '2025-12-31')", compiled('born_on', 'between', '2025-01-01,2025-12-31')
      end

      test 'a value the column cannot hold compiles to FALSE, with or without include_nulls' do
        [%w[small_count equal 5_id], %w[small_count not_equal abc], ['small_count', 'in', '5, 5x'], %w[small_count not_in x],
         %w[small_count between 5], ['small_count', 'between', '1,2,3'], %w[flag equal maybe], %w[flag not_equal 2],
         %w[born_on between 2026-01-10], ['seen_at', 'in', ''], %w[status equal deleted], %w[owner_id in current_user],
         %w[flag equal current_user], %w[born_on equal current_user], ['small_count', 'in', ''],
         %w[ratio less_than 1e309]].each do |field, operator, value|
          assert_equal 'FALSE', compiled(field, operator, value), "#{field} #{operator} #{value}"
          assert_equal 'FALSE', compiled(field, operator, value, include_nulls: true), "#{field} #{operator} #{value} +nulls"
        end
      end

      test 'a date or time that is not ISO 8601 is FALSE, except for PostgreSQL, which gets it as written' do
        { %w[born_on less_than today] => "(#{col('born_on')} < 'today')",
          ['seen_at', 'not_equal', ' 10.01.2026 '] => "(#{col('seen_at')} <> ' 10.01.2026 ')",
          ['born_on', 'in', '2026-01-10, someday'] => "(#{col('born_on')} IN ('2026-01-10', 'someday'))",
          %w[opens_at greater_than noon] => "(#{col('opens_at')} > 'noon')" }.each do |(field, operator, value), as_written|
          assert_equal (postgres? ? as_written : 'FALSE'), compiled(field, operator, value), "#{field} #{operator} #{value}"
        end
      end

      test 'a PostgreSQL real column gets the text of the number, any other float column the number' do
        assert_equal "(#{col('rate')} = #{postgres? ? "'0.1'" : '0.1'})", compiled('rate', 'equal', ' +0.10 ')
        assert_equal "(#{col('rate')} IN (#{postgres? ? "'0.1', '7'" : '0.1, 7'}))", compiled('rate', 'in', '0.1, 7')
        assert_equal "(#{col('rate')} < 1#{'0' * 39}.0)", compiled('rate', 'less_than', '1e39')
        assert_equal "(#{col('rate')} BETWEEN 0.05 AND 0.1)", compiled('rate', 'between', '0.05,0.1')
        assert_equal "(#{col('rate')} BETWEEN #{postgres? ? "'0.05' AND '0.1'" : '0.05 AND 0.1'})", compiled('rate', 'between', '+0.05,.1')
        assert_equal "(#{col('rate')} = #{UID}::bigint)", compiled('rate', 'equal', 'current_user')
        assert_equal "(#{col('ratio')} = 0.1)", compiled('ratio', 'equal', '0.1')
      end

      test 'a field name that is not a name compiles to FALSE, whatever the rule' do
        [['flag.', 'equal', 'true'], ['small_count.', 'not_equal', '5'], ['pf_rule_records.flag.', 'is_not_null', ''],
         ['pf_rule_records..flag', 'in', 'true, false'], ['label.', 'contains', 'a']].each do |field, operator, value|
          assert_equal 'FALSE', compiled(field, operator, value), "#{field} #{operator}"
          assert_equal 'FALSE', compiled(field, operator, value, include_nulls: true), "#{field} #{operator} +nulls"
        end
      end

      test 'a join rule whose field name is not a name is compiled too, not skipped' do
        rule = add_rule('id.', 'equal', 'current_user')
        rule.update_columns(join_type: 'joins', field_accessor_path: 'owner')
        result = RlsPolicyGenerator.call(model_class: PfRuleRecord)

        assert_empty result[:skipped_rules]
        assert_equal 'FALSE', compiled_part(result[:statements].find { |s| s.include?('CREATE POLICY permission_forge_select') })

        rule.update_columns(field_name: 'id')

        assert_equal [:join_rule], RlsPolicyGenerator.call(model_class: PfRuleRecord)[:skipped_rules].pluck(:reason)
      end

      test 'include_nulls adds the NULL rows only where the application layer adds them' do
        %w[equal not_equal in not_in].each do |operator|
          assert_includes compiled('small_count', operator, '5', include_nulls: true), "OR #{col('small_count')} IS NULL"
        end
        { 'less_than' => '5', 'greater_than_or_equal' => '5', 'between' => '1,5', 'is_null' => '', 'is_not_null' => '' }.each do |operator, value|
          assert_not_includes compiled('small_count', operator, value, include_nulls: true), ' OR '
        end
        %w[contains not_contains starts_with ends_with].each do |operator|
          assert_not_includes compiled('notes', operator, 'x', include_nulls: true), ' OR '
        end
        assert_equal "(#{col('small_count')} IS NOT NULL)", compiled('small_count', 'is_not_null', '', include_nulls: true)
      end

      test 'a LIKE operator is ILIKE with the escaping of the application layer' do
        escape = "ESCAPE #{quote('\\')}"

        assert_equal "(#{col('notes')} ILIKE #{quote('%50\\%\\_off%')} #{escape})", compiled('notes', 'contains', '50%_off')
        assert_equal "(NOT #{col('notes')} ILIKE #{quote('%a\\\\b%')} #{escape})", compiled('notes', 'not_contains', 'a\\b')
        assert_equal "(#{col('label')} ILIKE #{quote('x%')} #{escape})", compiled('label', 'starts_with', 'x')
        assert_equal "(#{col('notes')} ILIKE '%' || (#{UID}::bigint)::text || '' #{escape})",
                     compiled('notes', 'ends_with', 'current_user')
      end

      # The app layer's ILIKE raises on PostgreSQL for a column that is not
      # text; a policy that matched the column's text would show rows the app
      # layer never shows.
      test 'a LIKE operator on a column that is not text compiles to FALSE' do
        %w[small_count owner_id amount ratio flag born_on seen_at opens_at status].each do |column|
          %w[contains not_contains starts_with ends_with].each do |operator|
            assert_equal 'FALSE', compiled(column, operator, '5'), "#{column} #{operator}"
            assert_equal 'FALSE', compiled(column, operator, 'current_user', include_nulls: true), "#{column} #{operator} current_user"
          end
        end
        assert_not_equal 'FALSE', compiled('tier', 'contains', 'G')
      end

      test 'current_user is the session id as the column type takes it' do
        assert_equal "(#{col('owner_id')} = #{UID}::bigint)", compiled('owner_id', 'equal', 'current_user')
        assert_equal "(#{col('status')} <> #{UID}::bigint)", compiled('status', 'not_equal', 'current_user')
        assert_equal "(#{col('ratio')} > #{UID}::bigint)", compiled('ratio', 'greater_than', 'current_user')
        assert_equal "(#{col('label')} = (#{UID}::bigint)::text)", compiled('label', 'equal', 'current_user')
        assert_equal "(#{col('small_count')} IS NULL)", compiled('small_count', 'is_null', 'current_user')
      end

      test 'an id that is not a number never equals a number column' do
        with_user_id_column(:uuid, 'uuid') do
          assert_equal 'FALSE', compiled('owner_id', 'equal', 'current_user')
          assert_equal 'FALSE', compiled('owner_id', 'not_equal', 'current_user', include_nulls: true)
          assert_equal "(#{col('label')} = (#{UID}::uuid)::text)", compiled('label', 'equal', 'current_user')
        end
      end

      test 'the digest follows what a rule compiles to, not only what it says' do
        add_rule('status', 'equal', 'archived')
        before = RlsPolicyGenerator.call(model_class: PfRuleRecord)[:digest]
        renumbered = PfRuleRecord.defined_enums.merge('status' => { 'active' => 0, 'archived' => 7 })

        PfRuleRecord.stub_enums(renumbered) do
          assert_includes policy_sql, "(#{col('status')} = 7)"
          assert_not_equal before, RlsPolicyGenerator.call(model_class: PfRuleRecord)[:digest]
        end
        assert_equal before, RlsPolicyGenerator.call(model_class: PfRuleRecord)[:digest]
      end

      test 'rules that differ only in include_nulls have a digest' do
        add_rule('small_count', 'less_than', '5', include_nulls: true)
        add_rule('small_count', 'less_than', '5', include_nulls: false)

        assert_match(/\A\h{64}\z/, RlsPolicyGenerator.call(model_class: PfRuleRecord)[:digest])
      end

      private

      def connection
        PfRuleRecord.connection
      end

      def postgres?
        connection.adapter_name == 'PostgreSQL'
      end

      def quote(value)
        connection.quote(value)
      end

      def col(name)
        "#{connection.quote_table_name('pf_rule_records')}.#{connection.quote_column_name(name)}"
      end

      # Without validation: an unusable value is one a rule can hold all the same.
      def add_rule(field_name, operator, field_value, include_nulls: false)
        PermissionForge::PermissionSetRule.new(
          uuid: SecureRandom.uuid, name: 'Compiled', permission_set: @permission_set, resource: @resource,
          field_name: field_name, operator: operator, field_value: field_value, include_nulls: include_nulls, is_active: true
        ).tap { |rule| rule.save!(validate: false) }
      end

      def policy_sql
        RlsPolicyGenerator.call(model_class: PfRuleRecord)[:statements].find { |s| s.include?('CREATE POLICY permission_forge_select') }
      end

      # The one rule's part of the policy: what follows the membership check.
      def compiled(field_name, operator, field_value, include_nulls: false)
        rule = add_rule(field_name, operator, field_value, include_nulls: include_nulls)
        compiled_part(policy_sql)
      ensure
        rule&.delete
      end

      def compiled_part(policy)
        policy[/AND \(psu\.expires_at IS NULL OR psu\.expires_at > now\(\)\) \) OR \((.*)\){6}\z/m, 1]
      end

      def with_user_id_column(type, sql_type)
        model = PermissionForge::PermissionSetUser
        columns = model.columns_hash.merge('user_id' => Struct.new(:type, :sql_type).new(type, sql_type))
        model.define_singleton_method(:columns_hash) { columns }
        yield
      ensure
        model.singleton_class.remove_method(:columns_hash)
      end
    end
  end
end
