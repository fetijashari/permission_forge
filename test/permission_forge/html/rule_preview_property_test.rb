require_relative 'admin_test_case'
require 'nokogiri'

module PermissionForge
  module Html
    # Field test round 7 (B#87): the rule builder's preview gave a reason the
    # save would not — "a, is not a value status can hold" for an "is
    # between" with one end typed, where the save says "Enter both ends of
    # the range." The preview now runs the save path in memory (RuleForm's
    # own checks, then the model's validations on the attributes the
    # sentence shows) and shows the first error the save would show, else
    # the sentence. Property: for every generated input, the preview's
    # message is the first error the save answers, and a save that goes
    # through has a preview with no error.
    class RulePreviewPropertyTest < AdminTestCase
      SEED = 20_261_016
      COUNT = 48
      FIELDS = %w[name email domain supplier_id created_at].freeze
      OPERATORS = Operators::Constants::OPERATORS
      SINGLE = ['', 'a', 'active', '5', '-3', '2026-01-01', 'x' * 3].freeze
      LISTS = ['', 'a', 'a, b', '5, x', ' , '].freeze
      ENDS = ['', 'a', '5', '2026-01-01'].freeze

      # One builder input: a field, an operator and the value inputs the
      # operator's value shape reads — chosen at random, so a list for a
      # number column, one end of a range, "the current user" on a date and
      # a blank value all come up.
      def self.inputs
        random = Random.new(SEED)
        Array.new(COUNT) do |index|
          operator = OPERATORS.sample(random: random)
          input = { name: "Generated #{index}", field_name: FIELDS.sample(random: random), operator: operator }
          case Admin::RuleForm::ARITY.fetch(operator)
          when :list then input[:values_text] = LISTS.sample(random: random)
          when :range then input.merge!(value_from: ENDS.sample(random: random), value_to: ENDS.sample(random: random))
          when :one
            random.rand(5).zero? ? input[:current_user] = '1' : input[:value] = SINGLE.sample(random: random)
          end
          input
        end
      end

      def rules_path(suffix = '')
        pf("/permission_sets/#{@set.id}/resources/Customer/rules#{suffix}")
      end

      # The save path: the first error the refused form shows, or nil when it saved.
      def save_first_error(input)
        post rules_path, params: { rule: input }
        return nil if response.redirect?

        assert_response :unprocessable_entity, input.inspect
        Nokogiri::HTML(response.body).css('.pf-sheet__footer-note .pf-error').map { |node| node.text.strip }.first
      end

      def preview_error(input)
        get rules_path('/preview'), params: { rule: input }, headers: { 'X-PF-Fragment' => '1' }
        assert_response :success, input.inspect
        Nokogiri::HTML(response.body).at_css('[data-pf-rule-preview-error]')&.text&.squish
      end

      test 'the generated inputs cover every value shape, refused and saved' do
        inputs = self.class.inputs
        assert_operator inputs.size, :>=, 40
        assert_equal OPERATORS.map { |op| Admin::RuleForm::ARITY.fetch(op) }.uniq.sort, inputs.map { |i| Admin::RuleForm::ARITY.fetch(i[:operator]) }.uniq.sort
        outcomes = inputs.map { |input| save_first_error(input).nil? }
        assert_includes outcomes, true, 'some inputs save'
        assert_includes outcomes, false, 'some inputs are refused'
      end

      test 'the preview says the first error the save would show, or none when the save goes through' do
        mismatches = self.class.inputs.filter_map do |input|
          saved_error = save_first_error(input)
          shown = preview_error(input)
          expected = saved_error && "⚠ #{I18n.t('permission_forge.permission_set_rules.builder.preview_refused')} #{saved_error}".squish
          "#{input.inspect}: save #{saved_error.inspect}, preview #{shown.inspect}" unless shown == expected
        end

        assert_empty mismatches, mismatches.join("\n")
      end

      test 'B#87: an "is between" with one end says the range needs both ends' do
        input = { name: 'Between', field_name: 'name', operator: 'between', value_from: 'a', value_to: '' }

        assert_equal "⚠ #{I18n.t('permission_forge.permission_set_rules.builder.preview_refused')} " \
                     "#{I18n.t('permission_forge.permission_set_rules.builder.errors.range')}", preview_error(input)
        I18n.with_locale(:mk) do
          get rules_path('/preview'), params: { rule: input, locale: 'mk' }, headers: { 'X-PF-Fragment' => '1' }
          assert_includes response.body, I18n.t('permission_forge.permission_set_rules.builder.errors.range', locale: :mk)
          assert_not_includes response.body, 'може да ја содржи', 'never "cannot hold" for a range missing an end'
        end
      end
    end
  end
end
