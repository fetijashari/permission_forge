require 'test_helper'

module PermissionForge
  module Services
    # G7 (EX — explanations come from the deciding predicate): whatever a
    # denial blames is what decided it. Over generated rule/record
    # combinations, NotAuthorizedError#failure_messages and #details, and the
    # access.denied event's `messages`, name exactly the rules whose
    # single-rule scope (PermissionRuleApplier.scope, the relation the
    # rules decide with) excludes the record, in rule order — and, when no
    # rule excludes it on its own, the cumulative attribution: the first rule
    # whose addition removes the record and every rule after it.
    #
    # Deterministic: a fixed seed, so a failure names a combination that
    # reproduces.
    class RuleBlamePropertyTest < ActiveSupport::TestCase
      SEED = 20_261_016
      COMBINATIONS = 60
      FALLBACK_COMBINATIONS = 12

      # Rules on Customer and through its supplier: filters and joins, valued
      # and valueless, with and without NULLs.
      RULE_POOL = [
        { field_name: 'name', operator: 'equal', field_value: 'alpha' },
        { field_name: 'name', operator: 'not_equal', field_value: 'beta' },
        { field_name: 'name', operator: 'in', field_value: 'alpha, gamma' },
        { field_name: 'name', operator: 'starts_with', field_value: 'g' },
        { field_name: 'domain', operator: 'is_null', field_value: '' },
        { field_name: 'domain', operator: 'is_not_null', field_value: '' },
        { field_name: 'domain', operator: 'equal', field_value: 'acme.test', include_nulls: true },
        { field_name: 'account_id', operator: 'greater_than', field_value: '5' },
        { field_name: 'account_id', operator: 'between', field_value: '1,10', include_nulls: true },
        { field_name: 'name', operator: 'equal', field_value: 'acme', field_accessor_path: 'supplier', join_type: 'joins' },
        { field_name: 'owner_id', operator: 'equal', field_value: 'current_user', field_accessor_path: 'supplier',
          join_type: 'left_joins', include_nulls: true },
        { field_name: 'owner_id', operator: 'is_not_null', field_value: '', field_accessor_path: 'supplier', join_type: 'joins' }
      ].freeze

      NAMES = %w[alpha beta gamma].freeze
      DOMAINS = [nil, 'acme.test', 'other.test'].freeze
      ACCOUNTS = [nil, 3, 7, 12].freeze

      setup do
        @user = create_user
        @set = create_permission_set(name: 'Blame')
        create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @suppliers = [nil, Supplier.create!(name: 'acme', owner_id: @user.id), Supplier.create!(name: 'other', owner_id: nil)]
        @random = Random.new(SEED)
        Current.user = @user
      end

      test 'a denial blames exactly the rules that exclude the record on their own, in rule order' do
        tally = Hash.new(0)
        COMBINATIONS.times do |index|
          rules = rules_for(index, pick_rules)
          record = create_customer(record_attributes)
          tally[check_combination(index, rules, record)] += 1
        end

        # The generator reaches every case the property is about.
        assert_operator tally[:allowed], :>=, 5, tally.inspect
        assert_operator tally[:one], :>=, 5, tally.inspect
        assert_operator tally[:several], :>=, 5, tally.inspect
      end

      # A custom operator that is not a mere filter (it inverts what the rules
      # before it constrain) denies only together with others: the blame is
      # the cumulative attribution, never no rule.
      test 'when no rule excludes the record on its own, the blame is the cumulative attribution' do
        registry = Operators::Registry.strategies.merge('invert' => INVERT)
        fallbacks = 0
        FALLBACK_COMBINATIONS.times do |index|
          rules = pick_rules.each_with_index.map do |attrs, position|
            hash = rule_hash(attrs, "R#{index}.#{position}")
            position == 1 ? hash.merge(operator: 'invert') : hash
          end
          record = create_customer(record_attributes)
          fallbacks += 1 if fallback_reached?(index, rules, record, registry)
        end

        assert_operator fallbacks, :>=, 1, 'the generator reaches the cumulative attribution'
      end

      INVERT = ->(query, *) { query.to_sql.include?(' WHERE ') ? query.invert_where : query }

      private

      def pick_rules
        RULE_POOL.sample(@random.rand(2..4), random: @random)
      end

      def record_attributes
        supplier = @suppliers.sample(random: @random)
        { name: NAMES.sample(random: @random), domain: DOMAINS.sample(random: @random),
          account_id: ACCOUNTS.sample(random: @random), supplier_id: supplier&.id }
      end

      # The combination's rules as stored rows; the rule hashes the user's
      # permission hash carries, in rule order.
      def rules_for(index, picked)
        @resource.permission_set_rules.reload.each(&:destroy!)
        picked.each_with_index do |attrs, position|
          create_permission_set_rule(permission_set: @set, resource: @resource, name: "R#{index}.#{position}",
                                     failure_message: "message #{index}.#{position}", include_nulls: false, **attrs)
        end
        @user.regenerate_permissions
        rules, = ResourceChain.rules(@user, [:Customer])
        assert_equal picked.size, rules.size, "combination #{index}: every rule reaches the hash"
        rules
      end

      def rule_hash(attrs, name)
        { name: name, failure_message: "message #{name}", include_nulls: false, join_type: nil,
          field_accessor_path: nil }.merge(attrs)
      end

      def keeps?(rules, record, registry: Operators::Registry)
        PermissionRuleApplier.scope(model_class: Customer, rules: rules, current_user: @user, operator_registry: registry)
                             .exists?(id: record.id)
      end

      # The rules whose single-rule scope excludes the record; else the
      # first rule whose addition removes it, and every rule after it.
      def expected_blame(rules, record, registry: Operators::Registry)
        alone = rules.reject { |rule| keeps?([rule], record, registry: registry) }
        return alone if alone.any?

        first = (1..rules.size).find { |count| !keeps?(rules.first(count), record, registry: registry) }
        first ? rules.drop(first - 1) : []
      end

      def describe(index, rules, record)
        "combination #{index}: #{rules.map { |r| r.slice(:field_accessor_path, :field_name, :operator, :field_value) }} " \
          "on #{record.attributes.slice('name', 'domain', 'account_id', 'supplier_id')}"
      end

      def check_combination(index, rules, record)
        context = describe(index, rules, record)
        if keeps?(rules, record)
          assert_equal record, Customer.find_by!(id: record.id), "#{context}: allowed"
          return :allowed
        end

        blamed = expected_blame(rules, record)
        assert_blame(context, blamed, record)
        blamed.size == 1 ? :one : :several
      end

      # NotAuthorizedError and access.denied name exactly the blamed rules.
      def assert_blame(context, blamed, record)
        error = assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError, context) do
          Customer.find_by!(id: record.id)
        end
        assert_equal blamed.pluck(:failure_message), error.failure_messages, "#{context}: failure_messages"
        details = blamed.map { |rule| "[Forbidden by Rule: #{rule[:name]}] with message: #{rule[:failure_message]}" }
        assert_equal details, error.details, "#{context}: details"
        assert_audit_event('access.denied', record_id: record.id.to_s, data: { 'messages' => details })
      end

      def fallback_reached?(index, rules, record, registry)
        _, messages, denying = PermissionRuleApplier.call(model_class: Customer, rules: rules, args: [{ id: record.id }],
                                                          current_user: @user, operator_registry: registry)
        expected = keeps?(rules, record, registry: registry) ? [] : expected_blame(rules, record, registry: registry)
        context = "fallback combination #{index}"
        assert_equal expected.pluck(:name), denying.pluck(:name), context
        assert_equal expected.size, messages.size, context
        alone = rules.reject { |rule| keeps?([rule], record, registry: registry) }
        expected.any? && alone.empty?
      end
    end
  end
end
