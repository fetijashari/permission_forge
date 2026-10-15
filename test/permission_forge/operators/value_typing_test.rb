# frozen_string_literal: true

require_relative '../rule_value_models'

module PermissionForge
  module Operators
    # A rule value gets the type of the column it is compared with, the same
    # way on every database. These are the Ruby values; what they select is in
    # test/permission_forge/services/rule_value_typing_test.rb.
    class ValueTypingTest < ActiveSupport::TestCase
      include RuleValueTestSupport

      UNUSABLE = ValueTyping::UNUSABLE
      ArrayColumn = Struct.new(:type) do
        def array? = true
      end
      # A column as PostgreSQL describes it, for the tests of what is typed
      # differently there: they run on every database.
      PostgresColumn = Struct.new(:type, :sql_type)
      REAL = PostgresColumn.new(:float, 'real')

      # Typed as on a database without casters of its own, whichever runs the
      # tests; `adapter:` names another.
      def typed(operator, value, column, adapter: 'SQLite')
        column = PfRuleRecord.columns_hash[column] if column.is_a?(String)
        enum = PfRuleRecord.defined_enums[column.name] if column.respond_to?(:name)
        ValueTyping.call(operator, value, RuleColumn.new(column, enum, adapter))
      end

      def assert_unusable(operator, value, column, adapter: 'SQLite')
        assert_same UNUSABLE, typed(operator, value, column, adapter: adapter), "#{column} #{operator} #{value.inspect} on #{adapter}"
      end

      # --- numbers ---

      test 'a whole number that fits 64 bits is an Integer, however it is written' do
        { '5' => 5, '+5' => 5, '-5' => -5, ' 5 ' => 5, '007' => 7, '-0' => 0, '5.' => 5, '50.0' => 50, '5e1' => 50,
          '1e3' => 1000, '1.5E1' => 15, '-2.0e0' => -2, '0.50e1' => 5, '0e999' => 0,
          '9223372036854775807' => (2**63) - 1, '-9223372036854775808' => -(2**63),
          '9223372036854775807.0' => (2**63) - 1 }.each do |text, number|
          %w[small_count owner_id amount ratio].each do |column|
            value = typed('equal', text, column)

            assert_kind_of Integer, value, "#{column} #{text}"
            assert_equal number, value, "#{column} #{text}"
          end
        end
      end

      test 'any other number is a BigDecimal, on an integer column too' do
        { '5.5' => '5.5', '+5.50' => '5.5', '-0.25' => '-0.25', '.5' => '0.5', '-2.5E-1' => '-0.25', '1e-3' => '0.001',
          '9223372036854775808' => '9223372036854775808', '99999999999999999999' => '99999999999999999999', '1e20' => '1e20',
          '12345678901234567.1234567891' => '12345678901234567.1234567891' }.each do |text, number|
          %w[small_count owner_id amount ratio].each do |column|
            value = typed('less_than', text, column)

            assert_kind_of BigDecimal, value, "#{column} #{text}"
            assert_equal BigDecimal(number), value, "#{column} #{text}"
          end
        end
      end

      test 'what is not a plain number is unusable on a number column' do
        ['5_id', 'abc', '', ' ', '4_2', 'NaN', 'Infinity', '0x5', '1e', 'e3', '1e3.5', '1e1000', '5,5', '--5', '+', '.', '5 5', nil,
         true].each do |value|
          %w[small_count amount ratio].each { |column| assert_unusable('equal', value, column) }
        end
      end

      test 'a number has to be one a double can hold' do
        assert_equal BigDecimal('1e308'), typed('less_than', '1e308', 'ratio')
        assert_equal BigDecimal('-2.5e-300'), typed('less_than', '-2.5e-300', 'amount')
        assert_equal 0, typed('equal', '0e999', 'small_count')
        ['1e309', '-1e999', '1e-400', "1#{'0' * 400}"].each do |value|
          %w[small_count amount ratio].each { |column| assert_unusable('less_than', value, column) }
        end
      end

      test 'the id current_user stands for is a number on a number column' do
        assert_equal 7, typed('equal', 7, 'owner_id')
        assert_equal 7, typed('equal', 7, 'ratio')
      end

      # --- booleans ---

      test 'a boolean column takes what PostgreSQL boolean input takes' do
        %w[true t yes y on 1 TRUE Yes].push(' on ', true).each { |value| assert_equal true, typed('equal', value, 'flag'), value.inspect }
        %w[false f no n off 0 FALSE Off].push(' no ', false).each { |value| assert_equal false, typed('equal', value, 'flag'), value.inspect }
      end

      test 'anything else is unusable on a boolean column, the id of current_user included' do
        ['abc', '', '2', 'tr', 'of', 'yes!', nil, 1, 0, 7].each { |value| assert_unusable('equal', value, 'flag') }
      end

      # --- text ---

      test 'a string column takes the value as written, and an id as its text' do
        assert_equal ' Acme ', typed('equal', ' Acme ', 'label')
        assert_equal '7', typed('equal', 7, 'label')
        assert_equal '5_id', typed('not_equal', '5_id', 'notes')
        assert_unusable('equal', nil, 'label')
        assert_unusable('less_than', nil, 'notes')
      end

      # --- dates and times ---

      test 'a date column takes an ISO 8601 date' do
        assert_equal Date.new(2026, 1, 10), typed('equal', '2026-01-10', 'born_on')
        assert_equal Date.new(2026, 1, 10), typed('equal', ' 2026-01-10T23:30:00+02:00 ', 'born_on')
        assert_equal Date.new(2026, 1, 5), typed('equal', '2026-1-5', 'born_on')
        [nil, 7].each { |value| assert_unusable('equal', value, 'born_on') }
      end

      test 'a datetime column takes an ISO 8601 date-time, read in the database time zone unless it says otherwise' do
        ten = Time.utc(2026, 1, 10, 10)
        ['2026-01-10 10:00:00', '2026-01-10T10:00', '2026-01-10T10:00:00Z', '2026-01-10 12:00:00+02:00',
         '2026-01-10T05:00:00-0500', '2026-01-10 12:00 +02', '2026-1-10 10:00'].each do |text|
          assert_equal ten, typed('greater_than', text, 'seen_at'), text
        end
        assert_equal Time.utc(2026, 1, 10), typed('greater_than', '2026-01-10', 'seen_at')
        assert_equal Time.utc(2026, 1, 10, 10, 0, 0, 250_000), typed('equal', '2026-01-10 10:00:00.25', 'seen_at')
        ['2026-02-30 10:00:00', '2026-01-10 10:61', '1768039200', nil, 7].each { |value| assert_unusable('less_than', value, 'seen_at') }
      end

      test 'a time column takes a time of day' do
        value = typed('less_than', '09:30', 'opens_at')

        assert_equal [9, 30, 0], [value.hour, value.min, value.sec]
        assert_equal value, typed('less_than', '2026-01-10 09:30:00', 'opens_at')
        assert_equal value, typed('less_than', ' 9:30 ', 'opens_at')
        ['930', '25:00', '09:60', '09:30+02:00', 'noon', '', nil, 7].each { |text| assert_unusable('less_than', text, 'opens_at') }
      end

      test 'what is not ISO 8601 is unusable on MySQL and SQLite and left to PostgreSQL as written' do
        { 'born_on' => ['today', ' tomorrow ', '10.01.2026', 'Jan 10 2026', '2026-02-30', 'abc', '5', ''],
          'seen_at' => ['now', 'infinity', '10.01.2026 10:00', '2026-01-10 25:00:00', 'abc', ''],
          'opens_at' => ['noon', '09:30+02:00', '25:00', 'abc', ''] }.each do |column, values|
          values.each do |value|
            %w[SQLite Mysql2 Trilogy].each { |adapter| assert_unusable('less_than', value, column, adapter: adapter) }
            %w[PostgreSQL PostGIS].each do |adapter|
              assert_equal value, typed('less_than', value, column, adapter: adapter), "#{column} #{value.inspect} on #{adapter}"
            end
          end
        end
      end

      test 'on PostgreSQL an ISO 8601 value is typed like anywhere, and what is not text stays unusable' do
        assert_equal Date.new(2026, 1, 10), typed('equal', '2026-01-10', 'born_on', adapter: 'PostgreSQL')
        assert_equal Time.utc(2026, 1, 10, 10), typed('equal', '2026-01-10 12:00:00+02:00', 'seen_at', adapter: 'PostgreSQL')
        assert_equal [Date.new(2026, 1, 10), 'today'], typed('in', '2026-01-10, today ', 'born_on', adapter: 'PostgreSQL')
        assert_equal %w[yesterday tomorrow], typed('between', 'yesterday,tomorrow', 'born_on', adapter: 'PostgreSQL')
        [nil, 7, true].each do |value|
          %w[born_on seen_at opens_at].each { |column| assert_unusable('equal', value, column, adapter: 'PostgreSQL') }
        end
        assert_unusable('between', 'today', 'born_on', adapter: 'PostgreSQL')
        assert_unusable('in', '', 'born_on', adapter: 'PostgreSQL')
      end

      test 'only the date and time casters and real columns differ on PostgreSQL' do
        %w[small_count owner_id amount ratio flag label notes status tier].each do |column|
          ['5', '5.5', 'yes', 'abc', '', 'archived', nil, 7].each do |value|
            %w[equal in between].each do |operator|
              expected = typed(operator, value, column)

              if expected.nil?
                assert_nil typed(operator, value, column, adapter: 'PostgreSQL')
              else
                assert_equal expected, typed(operator, value, column, adapter: 'PostgreSQL'), "#{column} #{operator} #{value.inspect}"
              end
            end
          end
        end
      end

      test 'the column of a model carries the adapter of that model' do
        caster = RuleColumn.find('born_on', [PfRuleRecord]).caster
        postgres = PfRuleRecord.connection.adapter_name == 'PostgreSQL'

        assert_equal Date.new(2026, 1, 10), caster.call('2026-01-10')
        assert_equal (postgres ? 'today' : UNUSABLE), caster.call('today')
      end

      # --- a single-precision column on PostgreSQL ---

      test 'a PostgreSQL real column takes the number as its text, to be read in single precision' do
        { '0.1' => '0.1', ' +0.10 ' => '0.1', '.5' => '0.5', '5' => '5', '-7' => '-7', '1e3' => '1000', '5.0' => '5', '0' => '0',
          '3e38' => "3#{'0' * 38}.0" }.each do |text, expected|
          value = typed('equal', text, REAL, adapter: 'PostgreSQL')

          assert_kind_of String, value, text
          assert_equal expected, value, text
        end
        assert_equal %w[0.1 7], typed('in', '0.1, 7', REAL, adapter: 'PostgreSQL')
        ['abc', '', '0x5', '1e999', nil].each { |value| assert_unusable('equal', value, REAL, adapter: 'PostgreSQL') }
        assert_unusable('in', '0.1, x', REAL, adapter: 'PostgreSQL')
      end

      # Before values were typed, `between` sent two plain integers or two plain
      # decimals as numbers and any other pair as text. A real column keeps that.
      test 'the bounds of between on a PostgreSQL real column go as they always did' do
        assert_equal [BigDecimal('0.05'), BigDecimal('0.1')], typed('between', '0.05, 0.1', REAL, adapter: 'PostgreSQL')
        assert_equal [1, 5], typed('between', '1,5', REAL, adapter: 'PostgreSQL')
        assert_equal %w[0.05 0.1], typed('between', '+0.05,.1', REAL, adapter: 'PostgreSQL')
        assert_equal %w[1 2.5], typed('between', '1,2.5', REAL, adapter: 'PostgreSQL')
        ['0.1', '0.1,x', '0.1,0.2,0.3', 'a,b', '0.1,1e999', nil].each do |value|
          assert_unusable('between', value, REAL, adapter: 'PostgreSQL')
        end
      end

      test 'a number no real can hold, and the id of current_user, stay numbers there' do
        assert_equal BigDecimal('1e39'), typed('less_than', '1e39', REAL, adapter: 'PostgreSQL')
        assert_equal BigDecimal('1e-39'), typed('greater_than', '1e-39', REAL, adapter: 'PostgreSQL')
        assert_equal 7, typed('equal', 7, REAL, adapter: 'PostgreSQL')
      end

      test 'a single-precision column anywhere else, and a double on PostgreSQL, take the number' do
        %w[SQLite Mysql2 Trilogy].each do |adapter|
          assert_equal BigDecimal('0.1'), typed('equal', '0.1', REAL, adapter: adapter), adapter
        end
        assert_equal BigDecimal('0.1'), typed('equal', '0.1', PostgresColumn.new(:float, 'double precision'), adapter: 'PostgreSQL')
        assert_equal BigDecimal('0.1'), typed('equal', '0.1', PostgresColumn.new(:decimal, 'numeric(30,10)'), adapter: 'PostgreSQL')
      end

      # --- enums ---

      test 'an enum label becomes the value the model stores for it' do
        assert_equal 1, typed('equal', 'archived', 'status')
        assert_equal 1, typed('equal', ' archived ', 'status')
        assert_equal 1, typed('equal', '1', 'status')
        assert_equal [0, 2], typed('in', 'active, hidden', 'status')
        assert_equal [0, 1], typed('between', 'active,archived', 'status')
        assert_unusable('equal', 'deleted', 'status')
        assert_unusable('in', 'active, deleted', 'status')
        assert_equal 'G', typed('equal', 'gold', 'tier')
        assert_equal 'G', typed('equal', 'G', 'tier')
      end

      test 'a value that is a label means that label, also when it is another label\'s stored value' do
        crossed = RuleColumn.new(PfRuleRecord.columns_hash['tier'], { 'low' => 'high', 'high' => 'low', 'mid' => 'M' }, 'SQLite')

        assert_equal 'low', ValueTyping.call('equal', 'high', crossed)
        assert_equal %w[high M M], ValueTyping.call('in', 'low, mid, M', crossed)
      end

      test 'a LIKE operator on an enum column gets the text, not the stored value of a label' do
        assert_equal 'gold', typed('contains', 'gold', 'tier')
        assert_equal 'archived', typed('starts_with', 'archived', 'status')
      end

      # --- lists and ranges ---

      test 'a list is an Array with every element typed, or unusable as a whole' do
        assert_equal [5, 999], typed('in', '5, 999', 'small_count')
        assert_equal [BigDecimal('1.5'), 2], typed('not_in', '1.5,2', 'amount')
        assert_equal [true, false], typed('in', 'yes, 0', 'flag')
        assert_equal ['a', 'b c', '', 'd'], typed('in', ' a ,b c,,d', 'label')
        assert_unusable('in', '5, 5x', 'small_count')
        assert_unusable('not_in', '5, 5x', 'small_count')
        assert_unusable('in', '', 'small_count')
        assert_unusable('not_in', nil, 'label')
        assert_unusable('not_in', ' , ', 'small_count')
      end

      test 'current_user in a list is an element like any other' do
        assert_not ValueTyping.current_user?('in', 'current_user')
        assert_not ValueTyping.current_user?('not_in', 'current_user')
        assert_not ValueTyping.current_user?('between', 'current_user')
        assert_equal ['current_user'], typed('in', 'current_user', 'label')
        assert_unusable('in', 'current_user', 'owner_id')
        assert_unusable('in', '5, current_user', 'owner_id')
      end

      test 'current_user stands for the id wherever one value is compared' do
        %w[equal not_equal less_than greater_than less_than_or_equal greater_than_or_equal
           contains not_contains starts_with ends_with my_custom_operator].each do |operator|
          assert ValueTyping.current_user?(operator, 'current_user'), operator
        end
        assert_not ValueTyping.current_user?('equal', 'current_users')
      end

      test 'between takes exactly two values, each typed for the column' do
        assert_equal [1, 9], typed('between', '1, 9', 'small_count')
        assert_equal [1, BigDecimal('9.5')], typed('between', '1,9.5', 'small_count')
        assert_equal [Date.new(2025, 1, 1), Date.new(2025, 12, 31)], typed('between', '2025-01-01,2025-12-31', 'born_on')
        assert_equal [false, true], typed('between', 'false,true', 'flag')
        assert_equal %w[5 50], typed('between', '5,50', 'label')
        ['5', '1,2,3', '', '5x,6y', '1,x', 'current_user', nil].each { |value| assert_unusable('between', value, 'small_count') }
        assert_unusable('between', 'a', 'label')
      end

      # --- what is left alone ---

      test 'a LIKE pattern is the text of the value, whatever the column' do
        %w[contains not_contains starts_with ends_with].each do |operator|
          assert_equal 'abc', typed(operator, 'abc', 'small_count')
          assert_equal '7', typed(operator, 7, 'label')
          assert_unusable(operator, nil, 'label')
        end
      end

      test 'the null checks and custom operators get the value as it came' do
        %w[is_null is_not_null my_custom_operator].each do |operator|
          assert_equal 'abc', typed(operator, 'abc', 'small_count')
          assert_equal 7, typed(operator, 7, 'flag')
          assert_nil typed(operator, nil, 'label')
        end
      end

      test 'a column nothing is known about leaves the value as it was before typing' do
        assert_equal '5_id', typed('equal', '5_id', 'no_such_column')
        assert_nil typed('equal', nil, 'no_such_column')
        assert_equal %w[a b], typed('in', ' a , b ', 'no_such_column')
        assert_equal [5, 50], typed('between', '5,50', 'no_such_column')
        assert_equal [Date.new(2025, 1, 1), Date.new(2025, 12, 31)], typed('between', '2025-01-01,2025-12-31', 'no_such_column')
        assert_equal %w[5 abc], typed('between', '5,abc', 'no_such_column')
        assert_unusable('between', '5', 'no_such_column')
      end

      test 'an array column is left alone' do
        target = RuleColumn.new(ArrayColumn.new(:integer), nil, 'PostgreSQL')

        assert_same ValueCasters::UNTYPED, target.caster
        assert_equal '{1,2}', ValueTyping.call('equal', '{1,2}', target)
        assert_equal ['{1', '2}'], ValueTyping.call('in', '{1,2}', target)
      end

      # --- which column a field name names ---

      test 'a dotted field name is resolved against the rule model and the models on its path' do
        path = [Customer, Supplier, User]

        assert_equal :boolean, RuleColumn.find('users.deactivated', path).column.type
        assert_equal 'supplier_id', RuleColumn.find('customers.supplier_id', path).column.name
        assert_equal 'owner_id', RuleColumn.find('suppliers.owner_id', path).column.name
        assert_equal 'id', RuleColumn.find('id', path).column.name
        assert_nil RuleColumn.find('accounts.id', path).column
        assert_nil RuleColumn.find('users.no_such_column', path).column
        assert_nil RuleColumn.find('id', []).column
        assert_nil RuleColumn.find('users.id', []).column
        assert_equal({ 'active' => 0, 'archived' => 1, 'hidden' => 2 }, RuleColumn.find('pf_rule_records.status', [PfRuleRecord]).enum)
        assert_nil RuleColumn.find('label', [PfRuleRecord]).enum
      end

      test 'a schema or database before the table is not looked at' do
        path = [Customer, Supplier, User]

        assert_equal :boolean, RuleColumn.find('public.users.deactivated', path).column.type
        assert_equal :boolean, RuleColumn.find("#{table_qualifier}.users.deactivated", path).column.type
        assert_equal 'owner_id', RuleColumn.find('catalog.schema.suppliers.owner_id', path).column.name
        assert_nil RuleColumn.find('users.accounts.id', path).column
      end

      test 'a name is looked up without regard to case where the database has none' do
        exact = RuleValueTestSupport::POSTGRES

        ['Flag', 'FLAG', 'pf_rule_records.FLAG', 'PF_RULE_RECORDS.flag', "#{table_qualifier}.Pf_Rule_Records.Flag"].each do |name|
          column = RuleColumn.find(name, [PfRuleRecord]).column

          exact ? assert_nil(column, name) : assert_equal('flag', column.name, name)
        end
        mapping = RuleColumn.find('Status', [PfRuleRecord]).enum

        exact ? assert_nil(mapping) : assert_equal(1, mapping['archived'])
        assert_equal 'flag', RuleColumn.find('flag', [PfRuleRecord]).column.name
      end

      test 'a column the model ignores is still a column of the table' do
        assert_not_includes PfRuleSlimRecord.column_names, 'flag'
        assert_equal :boolean, RuleColumn.find('flag', [PfRuleSlimRecord]).column.type
        assert_equal :integer, RuleColumn.find('pf_rule_records.status', [PfRuleSlimRecord]).column.type
        assert_same UNUSABLE, ValueTyping.call('equal', 'maybe', RuleColumn.find('flag', [PfRuleSlimRecord]))
      end

      test 'a column the table does not have is missing: no value is usable with it under a built-in operator' do
        ['no_such_column', 'pf_rule_records.no_such_column', "#{table_qualifier}.pf_rule_records.nope"].each do |name|
          target = RuleColumn.find(name, [PfRuleRecord])

          assert_predicate target, :missing?, name
          assert_not_predicate target, :malformed?, name
          assert_equal PfRuleRecord, target.model, name
          Constants::OPERATORS.each do |operator|
            assert_same UNUSABLE, ValueTyping.call(operator, '5', target), "#{name} #{operator}"
            assert ValueTyping.no_column?(operator, target), "#{name} #{operator}"
          end
          assert_equal '5', ValueTyping.call('my_custom_operator', '5', target), 'a custom operator decides itself'
        end
        assert_equal User, RuleColumn.find('nope', [Customer, Supplier, User]).model
        assert_equal Supplier, RuleColumn.find('suppliers.nope', [Customer, Supplier, User]).model
      end

      test 'a column that is there, or a table that is none of the rule\'s, is not missing' do
        found = RuleColumn.find('flag', [PfRuleRecord])

        assert_not_predicate found, :missing?
        assert_equal PfRuleRecord, found.model
        [RuleColumn.find('elsewhere.flag', [PfRuleRecord]), RuleColumn.find('flag', []), RuleColumn.find('flag.', [PfRuleRecord])].each do |target|
          assert_not_predicate target, :missing?
          assert_nil target.model
        end
        assert_equal '5', ValueTyping.call('equal', '5', RuleColumn::UNKNOWN), 'nothing known: left to the database'
      end

      test 'a field name with an empty segment is not a name, and no value is usable with it' do
        ['flag.', '.flag', 'pf_rule_records.flag.', 'pf_rule_records..flag', '.', '..', '', nil].each do |name|
          target = RuleColumn.find(name, [PfRuleRecord])

          assert_not RuleColumn.name?(name), name.inspect
          assert_predicate target, :malformed?, name.inspect
          %w[equal not_equal in between contains is_null is_not_null my_custom_operator].each do |operator|
            assert_same UNUSABLE, ValueTyping.call(operator, 'true', target), "#{name.inspect} #{operator}"
          end
        end
        ['flag', 'pf_rule_records.flag', 'a.b.c', 'no_such_column', 'elsewhere.flag'].each do |name|
          assert RuleColumn.name?(name), name
          assert_not_predicate RuleColumn.find(name, [PfRuleRecord]), :malformed?, name
        end
      end
    end
  end
end
