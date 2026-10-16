# frozen_string_literal: true

require_relative '../rule_value_models'

module PermissionForge
  module Services
    # A rule selects the same rows on SQLite, MySQL and PostgreSQL: its value
    # is compared in the type of the column, and a value the column cannot hold
    # selects nothing. Without the typing MySQL converts the text ('5_id' is 5,
    # 'abc' is 0, 'true' is 0), SQLite compares it as text and PostgreSQL
    # raises.
    class RuleValueTypingTest < ActiveSupport::TestCase
      include RuleValueTestSupport

      NotAuthorizedError = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError
      NON_NULL = %w[big five zero].freeze

      setup do
        @user = create_user
        @other = create_user
        record('five', small_count: 5, owner_id: @user.id, amount: '5.5', ratio: 0.5, rate: 0.1, flag: true, notes: '50%_off',
                       born_on: '2026-01-10', seen_at: Time.utc(2026, 1, 10, 10), opens_at: '09:00', status: :active, tier: :basic)
        record('zero', small_count: 0, owner_id: @other.id, amount: 0, ratio: 0.0, rate: 0.5, flag: false, notes: '50x_off',
                       born_on: '2025-06-01', seen_at: Time.utc(2025, 6, 1), opens_at: '17:30', status: :archived, tier: :gold)
        record('big', small_count: 2_000_000_000, owner_id: 9_000_000_000, amount: '12345678901234567.1234567891',
                      ratio: 1e10, rate: 16_777_216, flag: true, notes: 'a\\b', born_on: '2030-12-31',
                      seen_at: Time.utc(2030, 12, 31, 23, 59, 59),
                      opens_at: '23:59:59', status: :hidden, tier: :gold)
        PfRuleRecord.create!(label: 'blank')
      end

      # --- numbers ---

      test 'a number column is compared with a number' do
        assert_equal %w[five], labels(:small_count, 'equal', '5')
        assert_equal %w[five], labels(:small_count, 'equal', ' +5 ')
        assert_equal %w[five], labels(:small_count, 'equal', '5.0')
        assert_equal %w[zero], labels(:small_count, 'equal', '-0')
        assert_equal %w[big five], labels(:small_count, 'not_equal', '0')
        assert_equal %w[five], labels(:amount, 'equal', '5.50')
        assert_equal %w[zero], labels(:ratio, 'less_than', '.25')
        assert_equal %w[five zero], labels(:amount, 'less_than', '1e3')
        assert_equal %w[five zero], labels(:small_count, 'less_than', '1e3')
        assert_equal %w[big], labels(:ratio, 'equal', '1E10')
        assert_equal %w[five], labels(:owner_id, 'equal', @user.id.to_s)
      end

      # `owner_id = 50.0` makes PostgreSQL cast the column of every row to
      # numeric; `owner_id = 50` can use the column's index.
      test 'a whole number written as a decimal reaches an integer column as an integer' do
        connection = PfRuleRecord.connection
        column = "#{connection.quote_table_name('pf_rule_records')}.#{connection.quote_column_name('owner_id')}"

        ['50', '50.0', '5e1', ' +50.00 ', '0.5e2'].each do |value|
          sql = scoped(field_name: 'owner_id', operator: 'equal', field_value: value).to_sql

          assert_includes sql, "(#{column} = 50)", value
        end
        assert_includes scoped(field_name: 'owner_id', operator: 'in', field_value: '5.0, 1e1, 2.5').to_sql, 'IN (5, 10, 2.5)'
        assert_includes scoped(field_name: 'owner_id', operator: 'between', field_value: '1.0,1e2').to_sql, 'BETWEEN 1 AND 100'
        assert_equal %w[five], labels(:small_count, 'equal', '0.5e1')
      end

      test 'text that is not a number matches no row of a number column' do
        ['5_id', 'abc', '', '4_2', 'NaN', '0x5', '1e', '5 5'].each do |value|
          %i[small_count owner_id amount ratio].each do |column|
            assert_empty labels(column, 'equal', value), "#{column} equal #{value.inspect}"
            assert_empty labels(column, 'greater_than_or_equal', value), "#{column} >= #{value.inspect}"
          end
        end
      end

      test 'a decimal on an integer column compares numerically' do
        assert_equal %w[five zero], labels(:small_count, 'less_than', '5.5')
        assert_equal %w[zero], labels(:small_count, 'less_than', '4.5')
        assert_equal %w[big five], labels(:small_count, 'greater_than', '4.5')
        assert_equal %w[big], labels(:small_count, 'greater_than_or_equal', '5.5')
        assert_empty labels(:small_count, 'equal', '5.5')
        assert_equal NON_NULL, labels(:small_count, 'not_equal', '5.5')
        assert_equal %w[five zero], labels(:owner_id, 'less_than_or_equal', "#{[@user.id, @other.id].max}.5")
      end

      test 'a number past the range of the column compares numerically and never raises' do
        %w[3000000000 9223372036854775808 99999999999999999999 1e300].each do |huge|
          %i[small_count owner_id].each do |column|
            assert_empty labels(column, 'equal', huge), "#{column} equal #{huge}"
            assert_equal NON_NULL, labels(column, 'not_equal', huge), "#{column} not_equal #{huge}"
            assert_empty labels(column, 'in', "#{huge}, -#{huge}"), "#{column} in #{huge}"
          end
          assert_equal NON_NULL, labels(:small_count, 'between', "-#{huge},#{huge}"), "small_count between #{huge}"
          assert_equal NON_NULL, labels(:small_count, 'less_than', huge), "small_count < #{huge}"
          assert_empty labels(:small_count, 'greater_than', huge), "small_count > #{huge}"
          assert_equal NON_NULL, labels(:small_count, 'greater_than', "-#{huge}"), "small_count > -#{huge}"
        end
        assert_equal %w[big], labels(:owner_id, 'greater_than', '3000000000')
        assert_equal %w[five zero], labels(:owner_id, 'less_than', '3000000000')
      end

      test 'a number past the range of a double matches no row' do
        assert_equal NON_NULL, labels(:ratio, 'less_than', '1e300')
        assert_equal NON_NULL, labels(:ratio, 'greater_than', '-1e300')
        %w[1e309 -1e999 1e-400].each do |value|
          %i[small_count amount ratio].each do |column|
            %w[equal not_equal less_than greater_than in not_in].each do |operator|
              assert_empty labels(column, operator, value), "#{column} #{operator} #{value}"
            end
          end
        end
      end

      test 'a decimal list is compared exactly' do
        skip 'SQLite stores a decimal as a floating-point number' if SQLITE

        assert_equal %w[big], labels(:amount, 'in', '12345678901234567.1234567891, 7')
        assert_empty labels(:amount, 'in', '12345678901234567.1234567890, 7')
        assert_equal %w[big], labels(:amount, 'equal', '12345678901234567.1234567891')
        assert_empty labels(:amount, 'equal', '12345678901234567.1234567890')
        assert_equal %w[five zero], labels(:amount, 'not_in', '12345678901234567.1234567891')
        assert_equal NON_NULL, labels(:amount, 'not_in', '12345678901234567.1234567890')
      end

      # --- booleans ---

      test 'a boolean column is compared with a boolean' do
        %w[true t yes y on 1 TRUE].push(' On ').each do |value|
          assert_equal %w[big five], labels(:flag, 'equal', value), value
          assert_equal %w[zero], labels(:flag, 'not_equal', value), value
        end
        %w[false f no n off 0 False].push(' OFF ').each do |value|
          assert_equal %w[zero], labels(:flag, 'equal', value), value
          assert_equal %w[big five], labels(:flag, 'not_equal', value), value
        end
        assert_equal NON_NULL, labels(:flag, 'in', 'yes, no')
        assert_equal %w[zero], labels(:flag, 'not_in', 'yes')
      end

      # ActiveRecord reads tinyint(1) as a boolean, and so does a rule: the
      # column is compared with TRUE or FALSE whatever else it holds.
      test 'a MySQL tinyint(1) column that holds other numbers is still a boolean' do
        skip 'MySQL-only column type' unless MYSQL

        PfRuleRecord.where(label: 'big').update_all('flag = 2')

        assert_equal %w[five], labels(:flag, 'equal', 'true')
        assert_equal %w[zero], labels(:flag, 'equal', '0')
        assert_empty labels(:flag, 'equal', '2')
        assert_empty labels(:flag, 'not_equal', '2')
        assert_empty labels(:flag, 'in', '1, 2')
      end

      test 'text that is not a boolean matches no row of a boolean column' do
        ['abc', '', '2', 'tr', 'maybe'].each do |value|
          assert_empty labels(:flag, 'equal', value), value
          assert_empty labels(:flag, 'not_equal', value), value
          assert_empty labels(:flag, 'in', "true, #{value}"), value
        end
        assert_empty labels(:flag, 'equal', 'current_user')
      end

      test 'a rule on the boolean column of users matches the rows it names' do
        off = create_user(deactivated: true)
        mine = { id: [@user.id, off.id] }

        assert_equal [off], scoped(User, operator: 'equal', field_name: 'deactivated', field_value: 'true').where(mine).to_a
        assert_equal [@user], scoped(User, operator: 'equal', field_name: 'deactivated', field_value: 'false').where(mine).to_a
        assert_equal [@user], scoped(User, operator: 'not_equal', field_name: 'deactivated', field_value: 'true').where(mine).to_a
      end

      # --- text ---

      test 'a string column is compared with text' do
        record('7', notes: 'seven')
        record('7abc', notes: 'seven and more')

        assert_equal %w[7], labels(:label, 'equal', '7')
        assert_equal %w[five], labels(:label, 'equal', 'five')
        assert_equal %w[7 7abc], labels(:label, 'in', '7, 7abc, 8')
        assert_equal %w[big blank], labels(:label, 'between', 'a,c')
        assert_equal %w[7 7abc], labels(:label, 'between', '5,8')
        assert_equal %w[7], labels(:notes, 'equal', 'seven')
      end

      # Case and accents are the collation's matter: MySQL's default collations
      # ignore both, PostgreSQL and SQLite compare exactly. Either way the rule
      # compares the way a plain query on the column does.
      test 'a string comparison follows the collation of the column' do
        record('Five')
        record('fivé')
        mysql = PfRuleRecord.connection.adapter_name.match?(/mysql|trilogy/i)

        %w[five FIVE Five fivé].each do |value|
          plain = PfRuleRecord.unscoped.where(label: value).pluck(:label).sort

          assert_equal plain, labels(:label, 'equal', value), value
          assert_equal plain, labels(:label, 'in', "#{value}, nothing"), value
        end
        assert_equal (mysql ? %w[Five five fivé] : %w[five]), labels(:label, 'equal', 'five')
      end

      test 'current_user on a string column matches the text of that id only' do
        exact = record(@user.id.to_s)
        record("#{@user.id}abc")

        assert_equal [exact.label], labels(:label, 'equal', 'current_user')
      end

      # --- dates and times ---

      test 'a date column is compared with a date' do
        assert_equal %w[five], labels(:born_on, 'equal', '2026-01-10')
        assert_equal %w[five], labels(:born_on, 'equal', '2026-01-10 18:30:00')
        assert_equal %w[big five], labels(:born_on, 'greater_than', '2025-12-31')
        assert_equal %w[five zero], labels(:born_on, 'less_than_or_equal', '2026-01-10')
        assert_equal %w[five], labels(:born_on, 'between', '2026-01-01,2026-12-31')
        assert_equal %w[big five], labels(:born_on, 'in', '2026-01-10, 2030-12-31')
      end

      test 'a datetime column is compared with a date-time' do
        assert_equal %w[five], labels(:seen_at, 'equal', '2026-01-10 10:00:00')
        assert_equal %w[five], labels(:seen_at, 'equal', '2026-01-10T10:00')
        assert_equal %w[five], labels(:seen_at, 'equal', '2026-01-10 12:00:00+02:00')
        assert_equal %w[big five], labels(:seen_at, 'greater_than', '2026-01-10T09:59:59Z')
        assert_equal %w[big], labels(:seen_at, 'greater_than', '2026-01-10T10:00')
        assert_equal %w[five zero], labels(:seen_at, 'less_than', '2026-01-11')
        assert_equal %w[zero], labels(:seen_at, 'between', '2025-01-01,2025-12-31')
        assert_equal %w[five zero], labels(:seen_at, 'not_in', '2030-12-31 23:59:59')
      end

      test 'a time column is compared with a time of day' do
        assert_equal %w[five], labels(:opens_at, 'less_than', '10:00')
        assert_equal %w[zero], labels(:opens_at, 'equal', '17:30:00')
        assert_equal %w[big zero], labels(:opens_at, 'between', '12:00,23:59:59')
      end

      test 'text that is not a date or a time matches no row of such a column on MySQL and SQLite' do
        skip 'PostgreSQL reads such text itself, as it always did (the next tests)' if POSTGRES

        ['abc', '5', 'today', 'now', '2026-02-30', '10.01.2026', ''].each do |value|
          %i[born_on seen_at opens_at].each do |column|
            %w[equal not_equal less_than greater_than].each do |operator|
              assert_empty labels(column, operator, value), "#{column} #{operator} #{value.inspect}"
            end
          end
        end
        assert_empty labels(:seen_at, 'between', '2025-01-01,zzz')
        assert_empty labels(:born_on, 'in', '2026-01-10, someday')
      end

      test 'on PostgreSQL a date or time in a notation of its own is left to PostgreSQL' do
        skip 'only PostgreSQL reads such text itself' unless POSTGRES

        { born_on: ['today', 'tomorrow', ' yesterday ', 'infinity', '10.01.2026', 'January 10, 2026'],
          seen_at: ['now', 'yesterday', '-infinity', 'January 10, 2026 10:00'],
          opens_at: ['09:00+02:00', '9:00 AM', 'allballs'] }.each do |column, values|
          values.product(%w[equal not_equal less_than greater_than_or_equal]).each do |value, operator|
            comparison = { 'equal' => '=', 'not_equal' => '<>', 'less_than' => '<', 'greater_than_or_equal' => '>=' }.fetch(operator)
            as_postgres_reads_it = PfRuleRecord.where("#{column} #{comparison} ?", value).pluck(:label).sort

            assert_equal as_postgres_reads_it, labels(column, operator, value), "#{column} #{operator} #{value.inspect}"
          end
        end
        assert_equal %w[five], labels(:born_on, 'equal', 'January 10, 2026')
        assert_equal NON_NULL, labels(:born_on, 'less_than', 'infinity')
        assert_equal %w[big five], labels(:born_on, 'in', '2026-01-10, 31 Dec 2030')
        assert_equal NON_NULL, labels(:seen_at, 'between', '-infinity,infinity')
      end

      test 'on PostgreSQL text it cannot read as a date still raises, as before values were typed' do
        skip 'only PostgreSQL reads such text itself' unless POSTGRES

        { born_on: ['abc', '2026-02-30', ''], seen_at: %w[abc 5], opens_at: ['abc', '25:00'] }.each do |column, values|
          values.each do |value|
            assert_raises(ActiveRecord::StatementInvalid, "#{column} #{value.inspect}") do
              PfRuleRecord.transaction(requires_new: true) { labels(column, 'less_than', value) }
            end
          end
        end
      end

      test 'what is not text is never a date or a time, on any database' do
        %i[born_on seen_at opens_at].each do |column|
          assert_empty labels(column, 'equal', 'current_user'), column
          assert_empty labels(column, 'not_equal', nil), column
          assert_empty labels(column, 'between', '2026-01-10'), column
        end
      end

      # --- a single-precision column ---

      # five holds 0.1, which no binary float is exactly. PostgreSQL reads the
      # rule's text as a `real` and SQLite has doubles only, so both find it.
      # MySQL compares a FLOAT column in double precision whatever it is
      # compared with (a quoted '0.1' as well), and 0.1 is not there.
      test 'a single-precision column is compared the way its database compares it' do
        tenth = MYSQL ? [] : %w[five]

        assert_equal tenth, labels(:rate, 'equal', '0.1')
        assert_equal tenth, labels(:rate, 'equal', ' +.10 ')
        assert_equal tenth, labels(:rate, 'in', '0.1')
        assert_equal tenth, labels(:rate, 'in', '0.1, 7')
        assert_equal tenth, labels(:rate, 'less_than_or_equal', '0.1')
        assert_equal NON_NULL - tenth, labels(:rate, 'not_equal', '0.1')
        assert_equal NON_NULL - tenth, labels(:rate, 'not_in', '0.1')
        assert_equal NON_NULL - tenth, labels(:rate, 'greater_than', '0.1')
        assert_equal %w[five zero], labels(:rate, 'between', '0.1,0.5')
      end

      # `between` with two plain decimals always went to PostgreSQL as numbers,
      # so there the bounds are compared in double precision, as on MySQL: a
      # stored 0.1 is just above 0.1. In any other notation they went as text.
      test 'between on a single-precision column keeps the bounds it always had' do
        assert_equal (SQLITE ? %w[five] : []), labels(:rate, 'between', '0.05,0.1')
        assert_equal (MYSQL ? [] : %w[five]), labels(:rate, 'between', '+0.05,.1')
        assert_equal %w[five zero], labels(:rate, 'between', '0.05,0.5')
        assert_equal %w[zero], labels(:rate, 'between', '0.2,1')
      end

      test 'a single-precision column takes any other number like a double' do
        assert_equal %w[zero], labels(:rate, 'equal', '0.5')
        assert_equal %w[zero], labels(:rate, 'equal', '5e-1')
        assert_equal %w[big], labels(:rate, 'greater_than', '1e6')
        assert_equal %w[five zero], labels(:rate, 'not_in', '16777216')
        assert_equal NON_NULL, labels(:rate, 'less_than', '1e39')
        assert_equal NON_NULL, labels(:rate, 'greater_than', '1e-39')
        assert_empty labels(:rate, 'equal', '1e39')
        ['abc', '', '0x5', '1e999', 'current_user,5'].each do |value|
          assert_empty labels(:rate, 'not_equal', value), value
          assert_empty labels(:rate, 'in', value), value
        end
      end

      test 'the text of the number goes to a PostgreSQL real column, the number to any other' do
        connection = PfRuleRecord.connection
        column = "#{connection.quote_table_name('pf_rule_records')}.#{connection.quote_column_name('rate')}"
        equal = scoped(field_name: 'rate', operator: 'equal', field_value: ' +0.10 ').to_sql
        huge = scoped(field_name: 'rate', operator: 'less_than', field_value: '1e39').to_sql

        assert_includes equal, "#{column} = #{POSTGRES ? "'0.1'" : '0.1'}"
        assert_includes huge, "#{column} < 1#{'0' * 39}.0"
      end

      # --- between ---

      test 'between takes two values of the column' do
        assert_equal %w[five zero], labels(:small_count, 'between', '0,5')
        assert_equal %w[five zero], labels(:small_count, 'between', ' -1 , 5.5 ')
        assert_equal %w[five], labels(:small_count, 'between', '5,5')
        assert_equal %w[five zero], labels(:amount, 'between', '0,5.5')
        assert_equal %w[five], labels(:ratio, 'between', '0.25,0.75')
        assert_equal NON_NULL, labels(:flag, 'between', 'false,true')
        assert_empty labels(:small_count, 'between', '5,0')
      end

      test 'between with anything but two values of the column matches nothing' do
        ['5', '0,5,9', 'a,b', '0,b', '', 'current_user', '1,current_user'].each do |value|
          assert_empty labels(:small_count, 'between', value), value.inspect
        end
        assert_empty labels(:label, 'between', 'a')
        assert_empty labels(:flag, 'between', 'no,perhaps')
      end

      # --- lists ---

      test 'in and not_in compare with every value of the list, typed' do
        assert_equal %w[five zero], labels(:small_count, 'in', '5, 0, 999')
        assert_equal %w[big], labels(:small_count, 'not_in', '5, 0, 999')
        assert_equal %w[five zero], labels(:amount, 'in', '5.5, 0')
        assert_equal %w[five], labels(:small_count, 'in', '5.0, 4.5')
      end

      test 'one unusable element makes the whole list unusable' do
        assert_empty labels(:small_count, 'in', '5, 5x')
        assert_empty labels(:small_count, 'not_in', '5, 5x')
        assert_empty labels(:small_count, 'not_in', '999, abc')
        assert_empty labels(:small_count, 'in', '')
        assert_empty labels(:small_count, 'not_in', '')
        assert_empty labels(:small_count, 'not_in', ' , ')
        assert_empty labels(:label, 'not_in', '')
      end

      test 'current_user inside a list is not replaced by the id' do
        record('current_user', owner_id: @user.id)

        assert_equal %w[current_user five], labels(:label, 'in', 'current_user, five')
        assert_empty labels(:owner_id, 'in', 'current_user')
        assert_empty labels(:owner_id, 'not_in', 'current_user')
        assert_empty labels(:owner_id, 'in', "#{@other.id}, current_user")
        assert_equal %w[current_user five], labels(:owner_id, 'equal', 'current_user')
        assert_equal %w[big zero], labels(:owner_id, 'not_equal', 'current_user')
      end

      # --- an unusable value ---

      test 'an unusable value matches nothing for the negative operators too' do
        assert_empty labels(:small_count, 'not_equal', '5_id')
        assert_empty labels(:small_count, 'not_in', '5_id')
        assert_empty labels(:flag, 'not_equal', 'abc')
        assert_empty labels(:born_on, 'not_equal', 'abc') unless POSTGRES
        assert_empty labels(:status, 'not_equal', 'deleted')
        assert_empty labels(:notes, 'not_contains', nil)
      end

      test 'include_nulls adds no row to a rule with an unusable value' do
        assert_equal %w[blank five], labels(:small_count, 'equal', '5', include_nulls: true)
        %w[equal not_equal in not_in].each do |operator|
          assert_empty labels(:small_count, operator, '5_id', include_nulls: true), operator
          assert_empty labels(:flag, operator, 'abc', include_nulls: true), operator
          assert_empty labels(:label, operator, nil, include_nulls: true), operator
        end
      end

      test 'a nil value is unusable for a comparison and no concern of the null checks' do
        %w[equal not_equal less_than greater_than in not_in between contains not_contains starts_with ends_with].each do |operator|
          %i[label notes small_count flag born_on].each do |column|
            assert_empty labels(column, operator, nil), "#{column} #{operator} nil"
          end
        end
        assert_equal %w[blank], labels(:notes, 'is_null', nil)
        assert_equal NON_NULL, labels(:notes, 'is_not_null', nil)
        assert_equal %w[blank], labels(:small_count, 'is_null', 'whatever')
      end

      test 'rules stay restrictions combined with AND' do
        rules = [rule(field_name: 'small_count', operator: 'less_than', field_value: '5.5'),
                 rule(field_name: 'flag', operator: 'equal', field_value: 'yes')]
        relation = PermissionRuleApplier.scope(model_class: PfRuleRecord, rules: rules, current_user: @user)

        assert_equal %w[five], relation.pluck(:label)

        rules << rule(field_name: 'status', operator: 'not_equal', field_value: 'deleted')

        assert_empty PermissionRuleApplier.scope(model_class: PfRuleRecord, rules: rules, current_user: @user)

        # A later rule cannot bring rows back, not even one that adds the NULL rows.
        rules = [rule(field_name: 'flag', operator: 'equal', field_value: 'maybe'),
                 rule(field_name: 'small_count', operator: 'not_equal', field_value: '7', include_nulls: true),
                 rule(field_name: 'label', operator: 'in', field_value: 'five, zero', include_nulls: true)]

        assert_empty PermissionRuleApplier.scope(model_class: PfRuleRecord, rules: rules, current_user: @user)
        assert_empty PermissionRuleApplier.scope(model_class: PfRuleRecord, rules: rules.reverse, current_user: @user)
      end

      # --- dotted field names ---

      test 'a dotted field name on the model table is typed like the plain one' do
        assert_equal %w[five], labels('pf_rule_records.small_count', 'equal', '5')
        assert_equal %w[five zero], labels('pf_rule_records.small_count', 'less_than', '5.5')
        assert_empty labels('pf_rule_records.small_count', 'equal', '5_id')
        assert_empty labels('pf_rule_records.small_count', 'not_equal', 'abc')
        assert_equal %w[zero], labels('pf_rule_records.flag', 'equal', 'no')
        assert_equal %w[zero], labels('pf_rule_records.status', 'equal', 'archived')
      end

      # Every spelling of a column name the database resolves is typed like the
      # plain one: without that, MySQL compares the value as text again ('true'
      # is the FALSE rows, '5_id' is 5) and SQLite's negative operators return
      # every row. PostgreSQL resolves a quoted name only as it is written.
      test 'a field name the database resolves is typed however it is spelled' do
        table = 'pf_rule_records'
        spellings = lambda do |column|
          qualified = ["#{table}.#{column}", "#{table_qualifier}.#{table}.#{column}"]
          next qualified if POSTGRES

          # Whether MySQL tells table names apart by case depends on the server; SQLite never does.
          qualified.push(column.upcase, column.capitalize, "#{table}.#{column.upcase}")
          SQLITE ? qualified.push("#{table.upcase}.#{column}") : qualified
        end

        spellings.call('flag').each do |name|
          assert_equal %w[big five], labels(name, 'equal', 'true'), name
          assert_equal %w[zero], labels(name, 'not_equal', 'yes'), name
          assert_empty labels(name, 'not_equal', 'maybe', include_nulls: true), name
        end
        spellings.call('small_count').each do |name|
          assert_empty labels(name, 'equal', '5_id'), name
          assert_empty labels(name, 'not_equal', 'abc', include_nulls: true), name
          assert_equal %w[five zero], labels(name, 'less_than', '5.5'), name
        end
        spellings.call('status').each do |name|
          assert_equal %w[zero], labels(name, 'equal', 'archived'), name
          assert_empty labels(name, 'not_in', 'active, deleted'), name
        end
      end

      # A column in another case is a column the table does not have: it
      # matches nothing. A table in another case is no table of the rule's,
      # and is left to the database, which rejects it.
      test 'on PostgreSQL a name in another case is another name' do
        skip 'MySQL and SQLite have no case in column names (the test before)' unless POSTGRES

        %w[Flag FLAG pf_rule_records.FLAG].each do |name|
          assert_empty labels(name, 'equal', 'true'), name
          assert_empty labels(name, 'not_equal', 'true', include_nulls: true), name
        end
        assert_raises(ActiveRecord::StatementInvalid) do
          PfRuleRecord.transaction(requires_new: true) { labels('PF_RULE_RECORDS.flag', 'equal', 'true') }
        end
      end

      # The database would reject the query: every find_by / permission_scoped
      # of the rule's holders raised (a 500). Like a value the column cannot
      # hold, the rule now denies.
      test 'a column the table does not have matches nothing, under every built-in operator' do
        operators = { 'equal' => '5', 'not_equal' => '5', 'less_than' => '5', 'greater_than' => '5',
                      'less_than_or_equal' => '5', 'greater_than_or_equal' => '5',
                      'in' => '5, 0', 'not_in' => 'x', 'between' => '0,5', 'contains' => 'a', 'not_contains' => 'a',
                      'starts_with' => 'a', 'ends_with' => 'a', 'is_null' => '', 'is_not_null' => '' }

        assert_equal PermissionForge::Operators::Constants::OPERATORS.sort, operators.keys.sort
        %w[no_such_column onwer_id pf_rule_records.no_such_column].each do |name|
          operators.each do |operator, value|
            assert_empty labels(name, operator, value), "#{name} #{operator}"
            assert_empty labels(name, operator, value, include_nulls: true), "#{name} #{operator} +nulls"
          end
          assert_empty labels(name, 'equal', 'current_user'), "#{name} current_user"
        end
      end

      test 'a column the table at the end of a join path does not have matches nothing' do
        join = { join_type: 'joins', field_accessor_path: 'owner' }

        assert_empty labels('no_such_column', 'equal', 'x', **join)
        assert_empty labels('users.no_such_column', 'not_equal', 'x', **join)
        assert_empty labels('nope', 'is_null', '', join_type: 'left_joins', field_accessor_path: 'owner')
        # The column is looked up on the joined table, not the rule's own.
        assert_empty labels('small_count', 'equal', '5', **join)
        assert_equal %w[five], labels('users.id', 'equal', @user.id.to_s, **join)
      end

      # Where the columns cannot be told, the rule is left to the database as
      # before: a real table that is none of the rule's (the query may join
      # it). A qualifier naming no table at all matches nothing.
      test 'a table that is none of the rule\'s, or a custom operator, is still left to the database' do
        assert_raises(ActiveRecord::StatementInvalid) do
          PfRuleRecord.transaction(requires_new: true) { labels('customers.flag', 'equal', 'true') }
        end
        assert_empty labels('elsewhere.flag', 'equal', 'true'), 'no such table: matches nothing'
        custom = PermissionForge::Operators::Registry.strategies.merge(
          'equal' => PermissionForge::Operators::Registry.strategies.fetch('equal'),
          'anything' => ->(query, _column, _rule, value) { query.where(label: value) }
        )

        assert_equal %w[five], scoped(registry: custom, field_name: 'no_such_column', operator: 'anything', field_value: 'five')
          .pluck(:label)
        assert_empty scoped(registry: custom, field_name: 'no_such_column', operator: 'equal', field_value: 'five')
      end

      test 'a column the model ignores is typed like any other' do
        slim = ->(**attrs) { scoped(PfRuleSlimRecord, **attrs).pluck(:label).sort }

        assert_equal %w[big five], slim.call(field_name: 'flag', operator: 'equal', field_value: 'true')
        assert_empty slim.call(field_name: 'flag', operator: 'not_equal', field_value: 'maybe')
        assert_equal %w[zero], slim.call(field_name: 'status', operator: 'equal', field_value: '1')
        assert_empty slim.call(field_name: 'status', operator: 'not_equal', field_value: '1_id', include_nulls: true)
      end

      test 'a field name with an empty segment matches nothing, under any operator' do
        ['flag.', 'pf_rule_records.flag.', 'pf_rule_records..flag', '.flag', 'small_count.', '.', ''].each do |name|
          { 'equal' => 'true', 'not_equal' => 'true', 'in' => 'true, false', 'not_in' => 'x', 'between' => '0,5',
            'less_than' => '5', 'contains' => 'a', 'not_contains' => 'a', 'is_null' => '', 'is_not_null' => '' }.each do |operator, value|
            assert_empty labels(name, operator, value), "#{name.inspect} #{operator}"
            assert_empty labels(name, operator, value, include_nulls: true), "#{name.inspect} #{operator} +nulls"
          end
        end
        through_owner = { join_type: 'joins', field_accessor_path: 'supplier.owner' }

        assert_empty scoped(Customer, field_name: 'users.deactivated.', operator: 'equal', field_value: 'false', **through_owner)
        assert_empty scoped(Customer, field_name: 'deactivated.', operator: 'is_not_null', field_value: '', **through_owner)
      end

      test 'a custom operator is not handed a field name that is not one' do
        called = false
        registry = custom_registry('echo' => lambda { |query, _col, _rule, _value|
          called = true
          query
        })

        assert_empty scoped(registry:, field_name: 'flag.', operator: 'echo', field_value: 'x')
        assert_not called
      end

      test 'a join rule with a dotted field name is typed for the joined model' do
        active_owner = @user
        retired_owner = create_user(deactivated: true)
        mine = create_customer(name: 'mine', supplier: create_supplier(owner_id: active_owner.id))
        theirs = create_customer(name: 'theirs', supplier: create_supplier(owner_id: retired_owner.id))
        ours = { id: [mine.id, theirs.id] }
        through_owner = { join_type: 'joins', field_accessor_path: 'supplier.owner' }

        { 'users.deactivated' => { 'true' => [theirs], 'no' => [mine], 'abc' => [] },
          'deactivated' => { 'yes' => [theirs], 'f' => [mine], '2' => [] },
          'suppliers.owner_id' => { active_owner.id.to_s => [mine], "#{active_owner.id}_id" => [], 'current_user' => [mine] },
          'customers.name' => { 'theirs' => [theirs] } }.each do |field_name, expectations|
          expectations.each do |value, expected|
            relation = scoped(Customer, field_name: field_name, operator: 'equal', field_value: value, **through_owner)

            assert_equal expected, relation.where(ours).to_a, "#{field_name} equal #{value}"
          end
        end
        negated = scoped(Customer, field_name: 'users.deactivated', operator: 'not_equal', field_value: 'abc', **through_owner)

        assert_empty negated.where(ours)
      end

      test 'a dotted field name whose table is not on the path keeps its value as written' do
        sql = scoped(field_name: 'customers.small_count', operator: 'equal', field_value: '5_id').to_sql
        list = scoped(field_name: 'customers.small_count', operator: 'in', field_value: ' 5_id , 6').to_sql

        assert_includes sql, "= '5_id'"
        assert_includes list, "IN ('5_id', '6')"
      end

      # --- enums ---

      test 'an enum label is compared as the value the model stores' do
        assert_equal %w[zero], labels(:status, 'equal', 'archived')
        assert_equal %w[zero], labels(:status, 'equal', '1')
        assert_equal %w[big five], labels(:status, 'not_equal', 'archived')
        assert_equal %w[big five], labels(:status, 'in', 'active, hidden')
        assert_equal %w[zero], labels(:status, 'not_in', 'active, 2')
        assert_equal %w[five zero], labels(:status, 'between', 'active,archived')
        assert_equal %w[big zero], labels(:status, 'greater_than', 'active')
        assert_empty labels(:status, 'equal', 'deleted')
        assert_empty labels(:status, 'in', 'active, deleted')
        assert_equal %w[big zero], labels(:tier, 'equal', 'gold')
        assert_equal %w[big zero], labels(:tier, 'equal', 'G')
        assert_equal %w[five], labels(:tier, 'not_in', 'gold')
        assert_equal %w[big zero], labels(:tier, 'contains', 'g')
        assert_empty labels(:tier, 'contains', 'gold')
      end

      # --- LIKE ---

      test 'a LIKE operator matches %, _ and backslash literally' do
        assert_equal %w[five], labels(:notes, 'contains', '50%_off')
        assert_equal %w[five], labels(:notes, 'contains', '%')
        assert_equal %w[five zero], labels(:notes, 'contains', '_off')
        assert_equal %w[big zero], labels(:notes, 'not_contains', '50%_off')
        assert_equal %w[big zero], labels(:notes, 'not_contains', '%')
        assert_equal %w[five], labels(:notes, 'starts_with', '50%')
        assert_equal %w[five zero], labels(:notes, 'starts_with', '50')
        assert_equal %w[five], labels(:notes, 'ends_with', '%_off')
        assert_equal %w[big], labels(:notes, 'contains', 'a\\b')
        assert_equal %w[big], labels(:notes, 'contains', '\\')
        assert_equal %w[five zero], labels(:notes, 'not_contains', '\\')
        assert_empty labels(:notes, 'contains', '\\%')
      end

      test 'a LIKE operator states its escape character' do
        connection = PfRuleRecord.connection
        sql = scoped(field_name: 'notes', operator: 'not_contains', field_value: '50%_off').to_sql

        assert_includes sql, "#{connection.quote('%50\\%\\_off%')} ESCAPE #{connection.quote('\\')}"
      end

      test 'a LIKE pattern keeps meaning the same under NO_BACKSLASH_ESCAPES' do
        skip 'MySQL-only SQL mode' unless MYSQL
        skip 'under NO_BACKSLASH_ESCAPES the mysql2 driver cannot quote text at all (the next test)' if mysql2?

        with_no_backslash_escapes do
          assert_equal %w[five], labels(:notes, 'contains', '50%_off')
          assert_equal %w[big zero], labels(:notes, 'not_contains', '50%_off')
          assert_equal %w[big], labels(:notes, 'contains', 'a\\b')
        end
      end

      # Mysql2::Client#escape raises in that mode, for any text and whatever
      # asks for it: a rule with a text value raised before values were typed
      # and still does. A value that needs no quoting is not affected.
      test 'under NO_BACKSLASH_ESCAPES a text value raises with the mysql2 driver, as it always did' do
        skip 'mysql2-only: trilogy quotes text in that mode (the test before)' unless mysql2?

        with_no_backslash_escapes do
          assert_raises(ActiveRecord::StatementInvalid) { labels(:notes, 'contains', '50%_off') }
          assert_raises(ActiveRecord::StatementInvalid) { labels(:label, 'equal', 'five') }
          assert_equal %w[five], labels(:small_count, 'equal', '5')
          assert_equal %w[zero], labels(:flag, 'equal', 'no')
        end
        assert_equal %w[five], labels(:label, 'equal', 'five'), 'the mode is switched off again'
      end

      # --- array columns ---

      test 'an array column gets the value untouched' do
        skip 'PostgreSQL-only column type' unless POSTGRES

        record('listed', codes: [1, 2], tags: %w[a b])
        record('other', codes: [3], tags: %w[c])

        assert_equal %w[listed], labels(:codes, 'equal', '{1,2}')
        assert_equal %w[other], labels(:codes, 'not_equal', '{1,2}')
        assert_equal %w[listed], labels(:tags, 'equal', '{a,b}')
        assert_equal %w[other], labels(:codes, 'greater_than', '{2}')
      end

      # --- custom operators ---

      test 'a custom operator gets its value as written and always runs' do
        seen = []
        registry = custom_registry('divisible_by' => lambda { |query, _col, rule, value|
          seen << value
          query.where('small_count % ? = 0', Integer(rule[:field_value]))
        })

        assert_equal %w[big five zero], scoped(registry:, field_name: 'small_count', operator: 'divisible_by', field_value: '5').pluck(:label).sort
        assert_equal ['5'], seen

        seen.clear
        echo = custom_registry('echo' => lambda { |query, _col, _rule, value|
          seen << value
          query
        })
        ['5_id', ' a , b ', nil, 'current_user'].each do |value|
          %w[small_count flag label no_such_column].each do |column|
            scoped(registry: echo, field_name: column, operator: 'echo', field_value: value).to_a
          end
        end

        assert_equal (['5_id'] * 4) + ([' a , b '] * 4) + ([nil] * 4) + ([@user.id] * 4), seen
      end

      test 'a built-in list operator always hands its strategy an Array' do
        seen = {}
        spy = lambda { |query, _col, rule, value|
          seen[rule[:field_name]] = value
          query
        }
        registry = custom_registry('in' => spy, 'not_in' => spy, 'between' => spy)

        { 'small_count' => [1, 2], 'amount' => [1, 2], 'label' => %w[1 2], 'customers.small_count' => %w[1 2] }.each do |column, expected|
          %w[in not_in].each do |operator|
            scoped(registry:, field_name: column, operator: operator, field_value: ' 1 , 2 ').to_a

            assert_equal expected, seen[column], "#{column} #{operator}"
          end
        end
        { 'small_count' => [1, 2], 'label' => %w[1 2], 'customers.small_count' => [1, 2] }.each do |column, expected|
          scoped(registry:, field_name: column, operator: 'between', field_value: '1,2').to_a

          assert_equal expected, seen[column], "#{column} between"
        end
        %w[in not_in between].each do |operator|
          assert_empty scoped(registry:, field_name: 'no_such_column', operator: operator, field_value: '1,2')
        end
        assert_not seen.key?('no_such_column'), 'a column the table does not have never reaches the strategy'
      end

      test 'a built-in strategy called without a typed value reads the rule text, as before' do
        registry = PermissionForge::Operators::Registry
        column = 'small_count'

        listed = registry.fetch('in').call(PfRuleRecord.all, column, rule(field_value: '5, 0'), '5, 0')
        ranged = registry.fetch('between').call(PfRuleRecord.all, column, rule(field_value: '1,9'), '1,9')

        assert_equal %w[five zero], listed.pluck(:label).sort
        assert_equal %w[five], ranged.pluck(:label)
      end

      # --- find_by ---

      test 'find_by lets a matching record through with one existence query' do
        permit_rule(field_name: 'small_count', operator: 'less_than', field_value: '5.5')
        five = PfRuleRecord.find_by(label: 'five')

        queries = capture_queries { assert_equal five, PfRuleRecord.find_by(label: 'five') }

        assert_equal 2, queries.size, queries.join("\n")
        assert_match(/\ASELECT 1 AS one/, queries.first)
      end

      test 'find_by denies an existing record when the rule value is unusable' do
        permit_rule(field_name: 'small_count', operator: 'not_equal', field_value: '5_id', failure_message: 'Not yours')

        error = assert_raises(NotAuthorizedError) { PfRuleRecord.find_by(label: 'five') }

        assert_includes error.details.first, 'Not yours'
        assert_nil PfRuleRecord.find_by(label: 'no such record')
        assert_empty PfRuleRecord.permission_scoped
      end

      test 'find_by follows an enum label and a boolean word' do
        permit_rule(field_name: 'status', operator: 'equal', field_value: 'archived')
        permit_rule(field_name: 'flag', operator: 'equal', field_value: 'off')

        assert_equal 'zero', PfRuleRecord.find_by(label: 'zero').label
        assert_raises(NotAuthorizedError) { PfRuleRecord.find_by(label: 'five') }
        assert_equal %w[zero], PfRuleRecord.permission_scoped.pluck(:label)
      end

      test 'under auto query scoping an unusable value hides every row and leaves creating one alone' do
        PermissionForge.configuration.auto_query_scoping = :filter_only
        permit_rule(field_name: 'small_count', operator: 'between', field_value: '5,5')

        assert_equal %w[five], PfRuleRecord.pluck(:label)
        assert_equal 5, PfRuleRecord.create!(label: 'made', small_count: 5).small_count

        permit_rule(field_name: 'flag', operator: 'not_equal', field_value: 'maybe')

        assert_empty PfRuleRecord.all
        assert_equal 0, PfRuleRecord.count
        assert PfRuleRecord.create!(label: 'made blind').persisted?
      ensure
        PermissionForge.configuration.auto_query_scoping = :off
      end

      private

      def mysql2?
        PfRuleRecord.connection.adapter_name == 'Mysql2'
      end

      # The mode is kept in a server-side variable and put back from it: with
      # the mysql2 driver nothing can be quoted while the mode is on, the mode
      # to restore included.
      def with_no_backslash_escapes
        connection = PfRuleRecord.connection
        connection.execute('SET @pf_sql_mode = @@SESSION.sql_mode')
        connection.execute("SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES')")
        yield
      ensure
        connection.execute('SET SESSION sql_mode = @pf_sql_mode')
      end

      # An operator registry with the built-in strategies and the given ones.
      def custom_registry(strategies)
        merged = PermissionForge::Operators::Registry.strategies.merge(strategies)
        Class.new do
          define_method(:fetch) { |name| merged.fetch(name) }
        end.new
      end

      def permit_rule(**attrs)
        @permission_set ||= create_permission_set.tap { |set| create_permission_set_user(user: @user, permission_set: set) }
        @resource ||= create_resource(permission_set: @permission_set, name: 'PfRuleRecord')
        create_permission_set_rule(permission_set: @permission_set, resource: @resource, include_nulls: false, **attrs)
        @user.invalidate_permissions
        Current.user = @user
      end

      # The statements the block asks for, the ones answered from the query
      # cache included; schema lookups and transaction control are left out.
      def capture_queries(&)
        queries = []
        counter = lambda do |_name, _start, _finish, _id, payload|
          queries << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
        end
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
        queries
      end
    end
  end
end
