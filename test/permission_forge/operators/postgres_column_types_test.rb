# frozen_string_literal: true

require_relative '../rule_value_models'

module PermissionForge
  module Operators
    # The PostgreSQL column types a rule value used to be handed over to
    # untyped (uuid, inet / cidr, json / jsonb, arrays, native enums): text
    # PostgreSQL cannot read as the column's type raised for every holder
    # (`invalid input syntax for type uuid: "banana"`). A value such a column
    # cannot hold now matches nothing, is refused when a rule is saved, and is
    # listed by the audit, as on every other column type (plan-final.md §2 SD,
    # WP-15). PostgreSQL only: the types exist nowhere else (the casters
    # themselves are tested on every database in value_typing_test.rb).
    class PostgresColumnTypesTest < ActiveSupport::TestCase
      include RuleValueTestSupport

      NotAuthorizedError = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError
      TOKEN = '7d1f0c0e-6f0a-4a57-9f0d-0f3f6f0a4a57'

      setup do
        skip 'PostgreSQL-only column types' unless POSTGRES

        @user = create_user
        record('five', ref: TOKEN, ip: '10.0.0.1', net: '10.0.0.0/24', settings: { 'a' => 1 }, aliases: %w[a b], mood: 'calm')
        record('zero', ref: '00000000-0000-0000-0000-000000000000', ip: '2001:db8::1', net: '2001:db8::/32', settings: {},
                       aliases: [], mood: 'angry')
        PfRuleRecord.create!(label: 'blank')
      end

      test "'banana' against a uuid column matches nothing, is refused on save and is listed by the audit" do
        %w[equal not_equal in not_in between].each do |operator|
          assert_equal [], labels(:ref, operator, 'banana'), operator
        end
        assert_equal [], labels(:ref, 'not_equal', 'banana', include_nulls: true)

        refused = new_rule(field_name: 'ref', field_value: 'banana')

        assert_not refused.valid?
        assert_includes refused.errors[:field_value], 'is not a value PfRuleRecord.ref can hold'

        rule = stored_rule(field_name: 'ref', field_value: 'banana')

        assert_equal :unusable_value, RuleProblem.for(rule).kind
        assert_raises(NotAuthorizedError) { PfRuleRecord.find_by(label: 'five') }
        assert_empty PfRuleRecord.permission_scoped.to_a
        assert_audit_lists(rule)
      end

      test 'a uuid column is compared with a uuid' do
        assert_equal %w[five], labels(:ref, 'equal', TOKEN.upcase)
        assert_equal %w[zero], labels(:ref, 'not_equal', " #{TOKEN} ")
        assert_equal %w[five zero], labels(:ref, 'in', "#{TOKEN}, 00000000-0000-0000-0000-000000000000")
        assert_equal [], labels(:ref, 'in', "#{TOKEN}, banana")
      end

      test 'current_user on a uuid column is a uuid only when the user id is one' do
        rule = stored_rule(field_name: 'ref', field_value: 'current_user')

        assert_nil RuleProblem.for(rule), 'whoever the user is: an id may be a uuid'
        assert_equal [], labels(:ref, 'equal', 'current_user'), 'an integer id is no uuid'
      end

      test 'an inet or cidr column is compared with an address or a network' do
        assert_equal %w[five], labels(:ip, 'equal', '10.0.0.1')
        assert_equal %w[five zero], labels(:ip, 'in', '10.0.0.1, 2001:db8::1')
        assert_equal %w[zero], labels(:net, 'equal', '2001:db8::/32')
        ['banana', '10.0.0.256', '10.0.0.1/255.255.255.0'].each { |value| assert_equal [], labels(:ip, 'equal', value), value }
        assert_equal [], labels(:net, 'equal', '10.0.0.5/24'), 'bits right of the mask: PostgreSQL raised'
      end

      test 'a json or array column matches nothing under every built-in operator but the null checks' do
        (Constants::OPERATORS - Validations::VALUELESS).each do |operator|
          %i[settings aliases codes tags].each do |column|
            assert_equal [], labels(column, operator, '{a}'), "#{column} #{operator}"
          end
        end
        assert_equal %w[five zero], labels(:settings, 'is_not_null', '')
        assert_equal %w[blank], labels(:aliases, 'is_null', '')
      end

      test 'a native enum column is compared with one of its labels' do
        assert_equal %w[five], labels(:mood, 'equal', 'calm')
        assert_equal %w[five], labels(:mood, 'less_than', 'angry'), 'in the order of the type'
        assert_equal %w[five zero], labels(:mood, 'in', 'calm, angry')
        assert_equal [], labels(:mood, 'equal', 'banana')
        assert_equal [], labels(:mood, 'not_in', 'calm, banana')
        assert_equal [], labels(:mood, 'equal', 'Calm')
      end

      # ALTER TYPE runs in the test's transaction (rolled back with it); a
      # label added there cannot be compared with until it commits, so only
      # the reading is asked.
      test 'a label added to the type while the process runs is read again once before it is refused' do
        assert_equal [], labels(:mood, 'equal', 'sleepy')
        PfRuleRecord.connection.execute("ALTER TYPE pf_rule_mood ADD VALUE 'bored'")

        assert_equal 'bored', ValueTyping.call('equal', 'bored', RuleColumn.find('mood', [PfRuleRecord]))
      ensure
        SchemaRead.reset!
      end

      test 'a LIKE operator on a uuid, network, json, array or enum column matches nothing instead of raising' do
        %i[ref ip net settings aliases mood].product(%w[contains not_contains starts_with ends_with]).each do |column, operator|
          assert_equal [], labels(column, operator, 'a'), "#{column} #{operator}"
        end
      end

      test 'each of these rules is named by RuleProblem and refused on save' do
        { ref: 'banana', ip: 'banana', net: '10.0.0.5/24', settings: '{"a":1}', aliases: '{a}', mood: 'banana' }.each do |column, value|
          assert_equal :unusable_value, RuleProblem.for(stored_rule(field_name: column.to_s, field_value: value))&.kind, column
          assert_not new_rule(field_name: column.to_s, field_value: value).valid?, column
        end
        { ref: TOKEN, ip: '10.0.0.1', net: '10.0.0.0/24', mood: 'calm' }.each do |column, value|
          assert new_rule(field_name: column.to_s, field_value: value).valid?, column
        end
        assert new_rule(field_name: 'settings', operator: 'is_not_null', field_value: '').valid?
      end

      # Text PostgreSQL reads itself (ValueCasters::PostgresqlTypes::ReadBack):
      # date and time text Temporal does not recognise, and every column type
      # no caster knows. PostgreSQL is asked once; what it cannot read matches
      # nothing instead of raising for every holder.
      test 'date text and types no caster knows are read back: what PostgreSQL cannot read matches nothing' do
        record('dated', born_on: Date.new(2026, 1, 31), period: 1.day, mac: '08:00:2b:01:02:03')

        { born_on: ['31 Jan 2026', 'banana'], period: ['1 day', 'banana'], mac: ['08:00:2b:01:02:03', 'zz'] }.each do |column, (readable, unreadable)|
          assert_equal %w[dated], labels(column, 'equal', readable), "#{column} #{readable}"
          %w[equal not_equal greater_than in].each do |operator|
            assert_equal [], labels(column, operator, unreadable), "#{column} #{operator} #{unreadable}"
          end
          assert_equal [], labels(column, 'between', "#{readable},#{unreadable}"), "#{column} between"
        end
        assert_equal %w[dated], labels(:label, 'equal', 'dated'), 'the transaction is still usable after a refused CAST'
      end

      # Review R1 #4: ReadBack asked whether PostgreSQL can read the value,
      # not whether it can compare it — CAST('<a/>' AS xml) succeeds, but xml
      # and point have no `=` (nor `<`), so every holder's query raised.
      test 'a type PostgreSQL cannot compare takes no value: xml and point match nothing, the null checks work' do
        record('shaped', doc: '<a/>', spot: '(1,2)')

        { doc: ['<a/>', '<a/>,<b/>'], spot: ['(1,2)', '(1,2),(3,4)'] }.each do |column, (one, two)|
          %w[equal not_equal less_than greater_than_or_equal].each do |operator|
            assert_equal [], labels(column, operator, one), "#{column} #{operator}"
          end
          assert_equal [], labels(column, 'in', two), "#{column} in"
          assert_equal [], labels(column, 'between', two), "#{column} between"
          assert_equal %w[shaped], labels(column, 'is_not_null', ''), "#{column} is_not_null"
          refused = new_rule(field_name: column.to_s, field_value: one)

          assert_not refused.valid?, column
          assert_includes refused.errors[:field_value], "is not a value PfRuleRecord.#{column} can hold"
        end
        assert_not SchemaRead.ordered_type?(PfRuleRecord, 'xml')
        assert_not SchemaRead.ordered_type?(PfRuleRecord, 'point')
        assert_not SchemaRead.ordered_type?(PfRuleRecord, 'no_such_type')
        %w[interval macaddr money date int4range].each { |type| assert SchemaRead.ordered_type?(PfRuleRecord, type), type }
      end

      test 'a value is asked of PostgreSQL once per process and type' do
        ValueCasters::PostgresqlTypes::ReadBack.reset!
        casts = 0
        counter = ->(*, payload) { casts += 1 if payload[:sql].to_s.start_with?('SELECT CAST(') }
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
          3.times { labels(:period, 'equal', 'banana') }
          labels(:period, 'equal', '2 days')
        end

        assert_equal 2, casts
      end

      test 'LIKE matches text columns only: an integer, a date or a boolean matches nothing instead of raising' do
        record('counted', small_count: 5, born_on: Date.new(2026, 5, 5), flag: true)

        { small_count: '5', born_on: '2026', flag: 't', period: 'day', ref: '7d1f' }.each do |column, value|
          %w[contains starts_with ends_with].each do |operator|
            assert_equal [], labels(column, operator, value), "#{column} #{operator}"
          end
        end
        assert_equal %w[counted], labels(:label, 'contains', 'unt')
      end

      # Field test round 7 (D#22): `small_count contains '1'` was refused as
      # "is not a value … can hold" on field_value; '1' is a good integer —
      # the operator is what an integer column cannot take.
      test 'a LIKE operator on an integer, date or boolean column is refused on operator, naming the column type' do
        { small_count: 'integer', born_on: 'date', flag: 'boolean' }.each do |column, type|
          rule = new_rule(field_name: column.to_s, operator: 'contains', field_value: '1')

          assert_not rule.valid?, column
          assert_equal [I18n.t('permission_forge.validations.permission_set_rule.pattern_on_non_text', model: 'PfRuleRecord',
                                                                                                       name: column.to_s, type: type)],
                       rule.errors[:operator], column
          assert_empty rule.errors[:field_value], column
          assert_equal :pattern_on_non_text, RuleProblem.for(stored_rule(field_name: column.to_s, operator: 'contains', field_value: '1')).kind
        end
      end

      private

      def resource
        @permission_set ||= create_permission_set.tap { |set| create_permission_set_user(user: @user, permission_set: set) }
        @resource ||= create_resource(permission_set: @permission_set, name: 'PfRuleRecord')
      end

      def new_rule(**attrs)
        PermissionForge::PermissionSetRule.new({ uuid: SecureRandom.uuid, name: 'New', failure_message: 'No', operator: 'equal',
                                                 include_nulls: false, permission_set: resource.permission_set,
                                                 resource: resource }.merge(attrs))
      end

      # A rule held by the user, its value written past the model (saved
      # before the check, or by another application on the shared tables).
      def stored_rule(field_value:, **attrs)
        rule = create_permission_set_rule(permission_set: resource.permission_set, resource: resource, name: "Stored #{attrs[:field_name]}",
                                          field_name: 'label', field_value: 'x', include_nulls: false)
        rule.update_columns(field_value: field_value, **attrs)
        @user.invalidate_permissions
        Current.user = @user
        rule.reload
      end

      def assert_audit_lists(rule)
        finding = Services::SecurityAudit.call.findings.find { |item| item.code == :unusable_rule_values }

        assert finding, 'rake permission_forge:audit reports unusable_rule_values'
        assert(finding.items.any? { |item| item.include?(rule.name) }, finding.items.inspect)
        assert_equal :medium, finding.severity
      end
    end
  end
end
