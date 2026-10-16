# frozen_string_literal: true

require_relative '../permission_forge/rule_value_models'

# Level 3 — an RLS policy selects the rows the application layer selects.
#
# Runs ONLY against PostgreSQL (`DB=postgres bundle exec rake test:rls`). For a
# matrix of operators, column types and values it compiles one rule with
# RlsPolicyGenerator, evaluates that expression in a WHERE clause and compares
# the rows with PermissionRuleApplier.scope for the same rule; a few rules then
# go through a real policy, read as a role policies apply to. Where the
# application layer's query raises (a LIKE operator on a number, text
# PostgreSQL cannot read as a uuid), the policy raises as well or shows no row:
# it is never the wider of the two.
class RlsRuleParityTest < ActiveSupport::TestCase
  include RuleValueTestSupport

  APP_ROLE = 'permission_forge_app'
  OPERATORS = PermissionForge::Operators::Constants::OPERATORS
  LIKE_OPERATORS = %w[contains not_contains starts_with ends_with].freeze

  # Good, odd and unusable values for a column of each kind. Lists and pairs
  # are in every set: each operator reads the same text its own way.
  NUMBERS = ['5', ' +5 ', '5.0', '5.5', '-1', '3000000000', '99999999999999999999', '5_id', 'abc', '', '1e3', '1e999', '1e-400', '0x5',
             '0,5', '0, 5.5', '5, 5x', '0,5,9', 'current_user', '5,current_user'].freeze
  BOOLEANS = ['true', 'YES', ' on ', '1', 'f', 'No', 'off', '0', 'abc', '', '2', 'tr', 'yes,no', 'false,true', 'yes,maybe',
              'current_user'].freeze
  TEXTS = ['five', 'FIVE', '5', '50%_off', '%', '_', 'a\\b', '\\', 'OFF', '', ' five ', 'a,m', 'five, zero', 'five,',
           'current_user', 'current_user,five'].freeze
  DATES = ['2026-01-10', '2026-01-10 18:30:00', '2026-01-10T10:00', '2026-01-10 12:00:00+02:00', '2025-12-31', '2026-1-10 9:00',
           '2026-02-30', '10.01.2026', 'today', 'abc', '5', '', '2025-01-01,2026-12-31', '2026-01-10, 2030-12-31',
           '2025-01-01,zzz', 'current_user'].freeze
  TIMES = ['09:00', '10:00:00', '17:30', '23:59:59', '9:00', '25:00', '0900', 'abc', '', '09:00,18:00', '09:00, 17:30',
           'current_user'].freeze
  STATUSES = ['archived', 'active', ' hidden ', '1', '2.0', 'deleted', 'ARCHIVED', '', 'active,archived', 'active, hidden',
              'active, deleted', 'current_user'].freeze
  TIERS = ['gold', 'basic', 'G', 'B', 'silver', '', 'basic,gold', 'gold, silver', 'current_user'].freeze

  # A char(n) column: its padding counts in a pattern and not in a comparison,
  # in the policy as in the application layer.
  CODES = ['ab', 'AB', 'ab  ', 'b', 'xyz', 'xyz ', 'abcd', 'abcde', '%', '', 'ab,xyz', 'a,b', 'current_user'].freeze

  UUIDS = ['7d1f0c0e-6f0a-4a57-9f0d-0f3f6f0a4a57', '7D1F0C0E-6F0A-4A57-9F0D-0F3F6F0A4A57', ' 7d1f0c0e-6f0a-4a57-9f0d-0f3f6f0a4a57 ',
           'banana', 'abc', '', '{7d1f0c0e-6f0a-4a57-9f0d-0f3f6f0a4a57}', '7d1f0c0e6f0a4a579f0d0f3f6f0a4a57',
           '7d1f0c0e-6f0a-4a57-9f0d-0f3f6f0a4a57,00000000-0000-0000-0000-000000000000',
           '7d1f0c0e-6f0a-4a57-9f0d-0f3f6f0a4a57, banana', 'current_user'].freeze
  INETS = ['10.0.0.1', '10.0.0.1/32', '10.0.0.0/24', '10.0.0.5/24', '2001:db8::1', ' 10.0.0.1 ', 'banana', '10.0.0.256',
           '10.0.0.1/255.255.255.0', '10.0.0.1/33', '', '10.0.0.1, 2001:db8::1', '10.0.0.1,banana', 'current_user'].freeze
  CIDRS = ['10.0.0.0/24', '10.0.0.5/24', '2001:db8::/32', '10.0.0.1', 'banana', '', '10.0.0.0/24, 2001:db8::/32',
           '10.0.0.0/24,banana', 'current_user'].freeze
  MOODS = ['calm', 'angry', ' calm ', 'Calm', 'banana', '', 'calm,angry', 'calm, angry', 'calm, banana', 'current_user'].freeze

  MATRIX = {
    small_count: NUMBERS, owner_id: NUMBERS, amount: NUMBERS, ratio: NUMBERS, rate: NUMBERS + %w[0.1 0.05,0.1 0.1,0.5 1e39],
    flag: BOOLEANS, label: TEXTS, notes: TEXTS,
    born_on: DATES, seen_at: DATES, opens_at: TIMES,
    status: STATUSES, tier: TIERS, code: CODES,
    ref: UUIDS, ip: INETS, net: CIDRS, mood: MOODS
  }.freeze
  # Columns no value is typed for (json, jsonb, arrays): every built-in
  # operator but the null checks matches nothing, in both layers. They used
  # to be left to PostgreSQL, which raised on most of them.
  OPAQUE = {
    codes: ['{1,2}', '{3}', '{}', '1', 'abc', '', '{1,2},{3}', '5,50', 'current_user'],
    tags: ['{a,b}', '{c}', 'a', '', '{a,b},{c}', 'current_user'],
    aliases: ['{a,b}', 'a', '', 'current_user'],
    settings: ['{"a": 1}', '{}', 'a', '', 'current_user']
  }.freeze

  # One rule of every Operators::RuleProblem kind — the rules the app layer
  # matches nothing for — on PfRuleRecord. A kind added to RuleProblem::KINDS
  # needs a case here (the first test below).
  KIND_RULES = {
    unknown_join_type: { join_type: 'inner', field_accessor_path: 'owner', field_name: 'id', operator: 'equal', field_value: '1' },
    unknown_association: { join_type: 'joins', field_accessor_path: 'ownr', field_name: 'id', operator: 'equal', field_value: '1' },
    unjoinable_association: { join_type: 'joins', field_accessor_path: 'subject', field_name: 'id', operator: 'equal',
                              field_value: '1' },
    unknown_operator: { field_name: 'label', operator: 'regex', field_value: 'five' },
    missing_column: { field_name: 'onwer_id', operator: 'equal', field_value: 'current_user' },
    unknown_table: { field_name: 'nosuch.label', operator: 'equal', field_value: 'five' },
    unusable_value: { field_name: 'ref', operator: 'equal', field_value: 'banana' }
  }.freeze
  # A field name that is not a name is a missing column to RuleProblem.
  MALFORMED_RULE = { field_name: 'label.', operator: 'not_equal', field_value: 'five' }.freeze

  setup do
    skip 'PostgreSQL-only enforcement suite (DB=postgres rake test:rls)' unless POSTGRES

    @user = create_user
    @other = create_user
    @permission_set = create_permission_set
    create_permission_set_user(user: @user, permission_set: @permission_set)
    @resource = create_resource(permission_set: @permission_set, name: 'PfRuleRecord')
    create_records
  end

  teardown do
    connection.execute('RESET ROLE') if POSTGRES
  end

  MATRIX.each_key do |column|
    test "the policy expression selects the app layer's rows for rules on #{column}" do
      assert_parity(column, OPERATORS, MATRIX.fetch(column))
    end
  end

  OPAQUE.each_key do |column|
    test "the policy expression selects the app layer's rows for rules on #{column}, which take no value" do
      assert_parity(column, OPERATORS, OPAQUE.fetch(column))
      (OPERATORS - PermissionForge::Operators::Validations::VALUELESS).each do |operator|
        assert_equal [[], []], compare(column, operator, OPAQUE.fetch(column).first, false), "#{column} #{operator}"
      end
    end
  end

  test 'every kind of rule the app layer matches nothing for has a parity case' do
    assert_equal PermissionForge::Operators::RuleProblem::KINDS.sort, KIND_RULES.keys.sort
  end

  KIND_RULES.merge(malformed_field_name: MALFORMED_RULE).each do |kind, attrs|
    test "a rule of kind #{kind} compiles to FALSE, selects nothing in both layers and syncs to a policy that hides every row" do
      rule = PermissionForge::PermissionSetRule.new(permission_set: @permission_set, resource: @resource, include_nulls: true, **attrs)

      assert_equal(kind == :malformed_field_name ? :missing_column : kind, PermissionForge::Operators::RuleProblem.for(rule)&.kind)
      assert_equal 'FALSE', generator.send(:rule_sql, rule)
      assert_empty app_layer_rows([attrs])
      assert_empty rows_through_policy([attrs.merge(include_nulls: true)])
      assert_empty PermissionForge::Services::RlsPolicyGenerator.call(model_class: PfRuleRecord)[:skipped_rules], 'compiled, not skipped'
    end
  end

  test 'current_user on a uuid column is the session id only where user ids are uuids' do
    rule = PermissionForge::PermissionSetRule.new(permission_set: @permission_set, resource: @resource, field_name: 'ref',
                                                  operator: 'equal', field_value: 'current_user', include_nulls: false)

    assert_equal 'FALSE', generator.send(:rule_sql, rule), 'an integer user id is never a uuid'
    with_user_id_column(:uuid, 'uuid') do
      assert_match(/ref" = NULLIF\(current_setting\('[^']+', true\), ''\)::uuid\)\z/,
                   PermissionForge::Services::RlsPolicyGenerator.new(model_class: PfRuleRecord).send(:rule_sql, rule))
    end
  end

  # "No activation condition" has one definition, PermissionSet.unconditional:
  # a text of blanks is no condition, one hour of the two is one. The policy
  # used to read the old one (no TRIM, the start hour only).
  test 'a set with only an end hour grants no view_all bypass in the policy' do
    hours = bypass_set('Hours only')
    hours.update_columns(allowed_hours_start: nil, allowed_hours_end: 17)

    assert_predicate hours.reload, :conditional?
    assert_equal %w[current_user five], policy_labels
  end

  test 'a set whose condition texts are blanks is unconditional to the policy, as to the app layer' do
    blanks = bypass_set('Blank conditions')
    blanks.update_columns(requires_session_flag: " \n", allowed_ips: "  \r\n\t")

    assert_predicate blanks.reload, :unconditional?
    assert_equal all_labels, app_layer_scoped_labels
    assert_equal all_labels, policy_labels
  end

  # PermissionSetUser.active_assignments counts an assignment until its
  # expires_at, that instant included; the policy reads now() the same way.
  test 'an assignment ending at the statement time still holds its member to the rules' do
    create_rules([{ field_name: 'owner_id', operator: 'equal', field_value: 'current_user' }])
    PermissionForge::RLS.sync!
    grant_app_role
    PermissionForge::PermissionSetUser.find_by!(user_id: @user.id, permission_set: @permission_set)
                                      .update_columns(expires_at: connection.select_value('SELECT now()'))

    assert_equal %w[current_user five], policy_labels
  end

  test 'a field name that is not a name selects nothing in both layers' do
    ['flag.', 'pf_rule_records.small_count.', 'pf_rule_records..label', '.label'].each do |name|
      { 'equal' => 'true', 'not_equal' => '5', 'not_in' => 'x', 'is_not_null' => '', 'contains' => 'a',
        'greater_than' => 'current_user' }.each do |operator, value|
        assert_equal [[], []], compare(name, operator, value, true), "#{name} #{operator}"
      end
    end
  end

  # Both layers used to raise: the app layer's query and the sync named a
  # column the table does not have. A name in another case is another name
  # on PostgreSQL.
  test 'a column the table does not have selects nothing in both layers, and syncs to a policy that hides every row' do
    %w[no_such_column onwer_id Flag pf_rule_records.Small_Count].each do |name|
      { 'equal' => 'true', 'not_equal' => '5', 'not_in' => 'x', 'is_null' => '', 'is_not_null' => '', 'contains' => 'a',
        'greater_than' => 'current_user' }.each do |operator, value|
        assert_equal [[], []], compare(name, operator, value, true), "#{name} #{operator}"
      end
    end
    rules = [{ field_name: 'onwer_id', operator: 'equal', field_value: 'current_user' }]

    assert_empty app_layer_rows(rules)
    assert_empty rows_through_policy(rules)
  end

  test 'the parity matrix is not vacuous' do
    selected = compare(:small_count, 'greater_than', '4.5', false)
    unusable = compare(:small_count, 'not_equal', '5_id', true)
    raising = compare(:small_count, 'contains', '5', false)

    assert_equal [%w[big five], %w[big five]], selected
    assert_equal [[], []], unusable
    assert_equal [:raises, []], raising
  end

  # PostgreSQL has no LIKE for a number, so the app layer raises. The policy
  # used to match the column's text instead, showing rows the app layer never
  # shows; it compiles to FALSE now.
  test 'a LIKE operator on a column that is not text raises in the app layer and shows no row in the policy' do
    %i[small_count amount flag born_on status].product(LIKE_OPERATORS).each do |column, operator|
      assert_equal [:raises, []], compare(column, operator, '5', false), "#{column} #{operator}"
      assert_equal [:raises, []], compare(column, operator, 'current_user', true), "#{column} #{operator} current_user"
    end
    # A uuid, network, json, array or native enum column: neither layer matches.
    %i[codes tags aliases settings ref ip net mood].product(LIKE_OPERATORS).each do |column, operator|
      assert_equal [[], []], compare(column, operator, '5', false), "#{column} #{operator}"
      assert_equal [[], []], compare(column, operator, 'current_user', true), "#{column} #{operator} current_user"
    end
    rules = [{ field_name: 'small_count', operator: 'contains', field_value: '5' }]

    assert_empty rows_through_policy(rules)
  end

  # The padding of a char(n) value counts in a pattern: 'ab' is stored as
  # 'ab  ' and does not end with 'ab'. Cast to text, as the policy used to
  # compare it, the padding is gone and the row was shown.
  test 'a pattern on a char(n) column sees the padded value in the policy too' do
    assert_equal [[], []], compare(:code, 'ends_with', 'ab', false)
    assert_equal [%w[big five], %w[big five]], compare(:code, 'starts_with', 'ab', false)
    assert_equal [%w[five], %w[five]], compare(:code, 'equal', 'ab', false)

    [[{ field_name: 'code', operator: 'ends_with', field_value: 'ab' }],
     [{ field_name: 'code', operator: 'not_contains', field_value: 'b ' }],
     [{ field_name: 'code', operator: 'starts_with', field_value: 'AB' }]].each do |rules|
      assert_equal app_layer_rows(rules), rows_through_policy(rules), rules.inspect
    end
  end

  test 'a policy made from the rules shows a plain role the rows the app layer selects' do
    [
      [{ field_name: 'small_count', operator: 'less_than', field_value: '5.5' }],
      [{ field_name: 'small_count', operator: 'not_equal', field_value: '3000000000' },
       { field_name: 'flag', operator: 'equal', field_value: 'yes' }],
      [{ field_name: 'status', operator: 'in', field_value: 'archived, hidden', include_nulls: true }],
      [{ field_name: 'notes', operator: 'not_contains', field_value: '50%', include_nulls: true }],
      [{ field_name: 'label', operator: 'equal', field_value: 'current_user' }],
      [{ field_name: 'owner_id', operator: 'equal', field_value: 'current_user', include_nulls: true }],
      [{ field_name: 'seen_at', operator: 'between', field_value: '2026-01-01,2026-12-31T23:59:59+02:00' }],
      [{ field_name: 'rate', operator: 'equal', field_value: '0.1' }],
      [{ field_name: 'rate', operator: 'not_in', field_value: '0.1, 16777216' }],
      [{ field_name: 'born_on', operator: 'less_than', field_value: 'January 11, 2026' }]
    ].each do |rules|
      expected = app_layer_rows(rules)

      assert_not_empty expected, rules.inspect
      assert_equal expected, rows_through_policy(rules), rules.inspect
    end
  end

  test 'a rule with an unusable value syncs to a policy that hides every row' do
    [
      [{ field_name: 'small_count', operator: 'not_equal', field_value: '5_id', include_nulls: true }],
      [{ field_name: 'flag', operator: 'equal', field_value: 'abc' }],
      [{ field_name: 'small_count', operator: 'greater_than', field_value: '0' },
       { field_name: 'born_on', operator: 'between', field_value: '2026-01-10' }],
      [{ field_name: 'flag', operator: 'equal', field_value: 'current_user' }]
    ].each do |rules|
      assert_empty app_layer_rows(rules), rules.inspect
      assert_empty rows_through_policy(rules), rules.inspect
    end
  end

  # A date in PostgreSQL's own words goes to PostgreSQL as written in both
  # layers. The app layer sends it with every query; a policy is parsed once,
  # so there `tomorrow` is the day after the policy was made — as it always was.
  test "PostgreSQL's own date words are read per query by the app layer and once by a policy" do
    rules = [{ field_name: 'born_on', operator: 'less_than', field_value: 'tomorrow' }]
    tomorrow = connection.select_value("SELECT 'tomorrow'::date::text")

    assert_includes scoped(**rules.first).to_sql, "< 'tomorrow'"
    assert_equal app_layer_rows(rules), rows_through_policy(rules)

    stored = connection.select_value(<<~SQL)
      SELECT pg_get_expr(polqual, polrelid) FROM pg_policy
      WHERE polname = 'permission_forge_select' AND polrelid = 'pf_rule_records'::regclass
    SQL

    assert_includes stored, "born_on < '#{tomorrow}'::date"
    assert_not_includes stored, 'tomorrow'
  end

  test 'a date PostgreSQL cannot read fails the sync, as before values were typed' do
    create_rules([{ field_name: 'born_on', operator: 'equal', field_value: 'someday' }])

    error = assert_raises(ActiveRecord::StatementInvalid) do
      PfRuleRecord.transaction(requires_new: true) { PermissionForge::RLS.sync! }
    end

    assert_match(/invalid input syntax for type date/, error.message)
  end

  # The bypass is dynamic, so it needs no resync; it stops with the row's
  # is_active in both layers (pre-release review core-security #6).
  test 'a switched-off view_all resource bypasses the rules in neither layer' do
    rules = [{ field_name: 'owner_id', operator: 'equal', field_value: 'current_user' }]
    create_rules(rules)
    PermissionForge::RLS.sync!
    grant_app_role
    bypass_set = create_permission_set(name: 'View all')
    create_permission_set_user(user: @user, permission_set: bypass_set)
    bypass = create_resource(permission_set: bypass_set, name: 'PfRuleRecord', view_all: true)
    Current.user = @user

    assert_equal all_labels, app_layer_scoped_labels
    assert_equal all_labels, policy_labels

    bypass.update!(is_active: false)

    assert_equal %w[current_user five], app_layer_scoped_labels
    assert_equal %w[current_user five], policy_labels
  end

  # The rules of a resource row are compiled whatever its is_active, and the
  # policy reads the row's state per statement: switched off at sync time or
  # back on after it, both layers agree without a re-sync (review MINOR-1).
  test 'a rule-bearing resource switched off at sync time, then on, is live in both layers without a re-sync' do
    create_rules([{ field_name: 'owner_id', operator: 'equal', field_value: 'current_user' }])
    @resource.update!(is_active: false)
    PermissionForge::RLS.sync!
    grant_app_role
    Current.user = @user

    assert_equal all_labels, app_layer_scoped_labels
    assert_equal all_labels, policy_labels

    @resource.update!(is_active: true)

    assert_equal %w[current_user five], app_layer_scoped_labels
    assert_equal %w[current_user five], policy_labels
    assert PermissionForge::RLS.drift_report.find { |row| row[:table] == 'pf_rule_records' }[:in_sync], 'nothing to re-sync'
  end

  # The same for the Permission Set itself (review round 2, MINOR-R2-1).
  test 'a rule-bearing set switched off at sync time, then on, is live in both layers without a re-sync' do
    create_rules([{ field_name: 'owner_id', operator: 'equal', field_value: 'current_user' }])
    @permission_set.update!(is_active: false)
    PermissionForge::RLS.sync!
    grant_app_role
    Current.user = @user

    assert_equal all_labels, app_layer_scoped_labels
    assert_equal all_labels, policy_labels

    @permission_set.update!(is_active: true)

    assert_equal %w[current_user five], app_layer_scoped_labels
    assert_equal %w[current_user five], policy_labels
    assert PermissionForge::RLS.drift_report.find { |row| row[:table] == 'pf_rule_records' }[:in_sync], 'nothing to re-sync'
  end

  test 'a user in no rule-bearing set is not held to the rules by the policy' do
    create_rules([{ field_name: 'flag', operator: 'equal', field_value: 'abc' }])
    PermissionForge::RLS.sync!
    grant_app_role

    visible = as_app_role { PermissionForge::RLS.with_user(@other) { PfRuleRecord.unscoped.pluck(:label) } }

    assert_equal PfRuleRecord.unscoped.count, visible.size
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def create_records
    record('five', small_count: 5, owner_id: @user.id, amount: '5.5', ratio: 0.5, rate: 0.1, flag: true, notes: '50%_off',
                   born_on: '2026-01-10', seen_at: Time.utc(2026, 1, 10, 10), opens_at: '09:00', status: :active, tier: :basic,
                   codes: [1, 2], tags: %w[a b], ref: '7d1f0c0e-6f0a-4a57-9f0d-0f3f6f0a4a57', code: 'ab',
                   aliases: %w[a b], settings: { 'a' => 1 }, ip: '10.0.0.1', net: '10.0.0.0/24', mood: 'calm')
    record('zero', small_count: 0, owner_id: @other.id, amount: 0, ratio: 0.0, rate: 0.5, flag: false, notes: '50x_OFF',
                   born_on: '2025-06-01', seen_at: Time.utc(2025, 6, 1), opens_at: '17:30', status: :archived, tier: :gold,
                   codes: [3], tags: %w[c], ref: '00000000-0000-0000-0000-000000000000', code: 'xyz',
                   aliases: [], settings: {}, ip: '2001:db8::1', net: '2001:db8::/32', mood: 'angry')
    record('big', small_count: 2_000_000_000, owner_id: 9_000_000_000, amount: '12345678901234567.1234567891', ratio: 1e10,
                  rate: 16_777_216, flag: true, notes: 'a\\b', born_on: '2030-12-31', seen_at: Time.utc(2030, 12, 31, 23, 59, 59),
                  opens_at: '23:59:59', status: :hidden, tier: :gold, codes: [], tags: [], code: 'abcd', ip: '10.0.0.5/24',
                  net: '10.0.0.0/8')
    record(@user.id.to_s, small_count: -1, notes: 'Five')
    record('current_user', owner_id: @user.id, notes: '%')
    PfRuleRecord.create!(label: nil)
  end

  # Every operator with every value, with and without include_nulls.
  def assert_parity(column, operators, values)
    cases = operators.product(values, [false, true])
    differing = cases.filter_map do |operator, value, include_nulls|
      app, policy = compare(column, operator, value, include_nulls)
      next if app == policy || (app == :raises && policy.empty?)

      "#{column} #{operator} #{value.inspect}#{' +nulls' if include_nulls}: app #{app.inspect}, policy #{policy.inspect}"
    end

    assert_empty differing, "#{differing.size} of #{cases.size} rules differ:\n#{differing.join("\n")}"
  end

  # @return [Array] what the app layer and the compiled policy expression select
  def compare(column, operator, value, include_nulls)
    attrs = { field_name: column.to_s, operator: operator, field_value: value, include_nulls: include_nulls }
    rule = PermissionForge::PermissionSetRule.new(permission_set: @permission_set, resource: @resource, **attrs)
    expression = generator.send(:rule_sql, rule)

    [selected { scoped(**attrs).pluck(:label) },
     selected { PermissionForge::RLS.with_user(@user) { PfRuleRecord.unscoped.where(expression).pluck(:label) } }]
  end

  def generator
    @generator ||= PermissionForge::Services::RlsPolicyGenerator.new(model_class: PfRuleRecord)
  end

  # The labels selected, or :raises. A savepoint keeps PostgreSQL's failed
  # statement from ending the test's own transaction.
  def selected(&)
    PfRuleRecord.transaction(requires_new: true, &).map(&:to_s).sort
  rescue ActiveRecord::StatementInvalid
    :raises
  end

  def app_layer_rows(rules)
    hashes = rules.map { |attrs| rule(**attrs) }
    PermissionForge::Services::PermissionRuleApplier.scope(model_class: PfRuleRecord, rules: hashes, current_user: @user)
                                                    .pluck(:label).map(&:to_s).sort
  end

  def all_labels
    PfRuleRecord.unscoped.pluck(:label).map(&:to_s).sort
  end

  # What the app layer selects for the current user, view_all bypass included.
  def app_layer_scoped_labels
    User.find(@user.id).regenerate_permissions
    PfRuleRecord.permission_scoped.pluck(:label).map(&:to_s).sort
  end

  def policy_labels
    as_app_role { PermissionForge::RLS.with_user(@user) { PfRuleRecord.unscoped.pluck(:label) } }.map(&:to_s).sort
  end

  # Replaces the set's rules, syncs the policies and reads as the app role.
  def rows_through_policy(rules)
    create_rules(rules)
    PermissionForge::RLS.sync!
    grant_app_role
    as_app_role { PermissionForge::RLS.with_user(@user) { PfRuleRecord.unscoped.pluck(:label) } }.map(&:to_s).sort
  end

  # Without validation: an unusable value is one a rule can hold all the same
  # (written through the API before a model changed, or straight to the table).
  def create_rules(rules)
    PermissionForge::PermissionSetRule.where(resource_id: @resource.id).delete_all
    rules.each_with_index do |attrs, index|
      rule = PermissionForge::PermissionSetRule.new(
        uuid: SecureRandom.uuid, name: "Rule #{index}", permission_set: @permission_set, resource: @resource,
        include_nulls: false, is_active: true, **attrs
      )
      rule.save!(validate: false)
    end
  end

  # A granting set holding @user that grants view_all on PfRuleRecord, with
  # the base set's rule (owner_id = current_user) synced.
  def bypass_set(name)
    create_rules([{ field_name: 'owner_id', operator: 'equal', field_value: 'current_user' }])
    PermissionForge::RLS.sync!
    grant_app_role
    set = create_permission_set(name: name)
    create_permission_set_user(user: @user, permission_set: set)
    create_resource(permission_set: set, name: 'PfRuleRecord', view_all: true)
    Current.user = @user
    set
  end

  # The user_id column as SchemaRead answers it, for the block.
  def with_user_id_column(type, sql_type)
    read = PermissionForge::SchemaRead.method(:column)
    user_id = Struct.new(:type, :sql_type).new(type, sql_type)
    replace_singleton_method(PermissionForge::SchemaRead, :column) do |model, name, &pick|
      model == PermissionForge::PermissionSetUser && name.to_s == 'user_id' ? user_id : read.call(model, name, &pick)
    end
    yield
  ensure
    replace_singleton_method(PermissionForge::SchemaRead, :column, read)
  end

  def grant_app_role
    connection.execute(<<~SQL)
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{APP_ROLE}') THEN
          CREATE ROLE #{APP_ROLE};
        END IF;
      END
      $$;
    SQL
    connection.execute("GRANT USAGE ON SCHEMA public TO #{APP_ROLE}")
    connection.execute("GRANT SELECT ON ALL TABLES IN SCHEMA public TO #{APP_ROLE}")
  end

  # Policies do not apply to a superuser, so the rows are read as a plain role.
  def as_app_role
    connection.execute("SET ROLE #{APP_ROLE}")
    yield
  ensure
    connection.execute('RESET ROLE')
  end
end
