module PermissionForge
  # How the admin draws a record rule that matches nothing (Operators::RuleProblem,
  # the one taxonomy the audit's rule check and Home share): a state with a
  # glyph and a word, and why — never the rule's sentence, which would read
  # like a rule that works. SentencesHelper asks here first.
  #
  # @api private
  module RuleProblemsHelper
    # Why the rule matches nothing (Operators::RuleProblem, the definition
    # the audit and Home share), or nil. Asked once per rule object.
    def pf_rule_problem(rule)
      @pf_rule_problems ||= {}.compare_by_identity
      return @pf_rule_problems[rule] if @pf_rule_problems.key?(rule)

      @pf_rule_problems[rule] = PermissionForge::Operators::RuleProblem.for(rule)
    end

    # "`stauts` is not a column of Customer": a name that is not there as
    # stored (RuleProblem#verbatim?: `onwer_id`, `ownr`, `regex`, `nosuch`),
    # so the admin recognises the typo — humanized it would read like a real
    # field; a real column or relationship by its label; a value as stored,
    # in code, next to its column's label. The sentence is the problem's
    # (RuleProblem#ui_key). The model may be none this app can load.
    def pf_rule_problem_text(problem)
      model = problem.model
      args = { name: pf_rule_problem_name(problem), model: (pf_resource_label(model.name) if model) }
      args[:value] = content_tag(:code, problem.value, class: 'pf-mono-key') if problem.value
      pf_ui("rules.problems.#{problem.ui_key}", **args)
    end

    def pf_rule_problem_name(problem)
      return content_tag(:code, problem.name, class: 'pf-mono-key') if problem.verbatim?

      problem.model ? pf_attribute_label(problem.model, problem.name) : problem.name
    end

    # "Matches nothing: `stauts` is not a column of Customer"
    def pf_rule_problem_line(problem)
      safe_join([pf_ui('rules.matches_nothing'), ': ', pf_rule_problem_text(problem)])
    end

    # The rule a one-line summary shows: one that matches nothing first.
    def pf_rule_headline(rules)
      rules.partition { |rule| pf_rule_problem(rule) }.flatten.first
    end

    # ◷ for a rule, ⊘ for one that matches nothing.
    def pf_rule_glyph(rule)
      pf_rule_problem(rule) ? '⊘' : '◷'
    end

    # [⊘ Matches nothing] Stauts is not a column of Customer  `stauts equal active`
    def pf_rule_problem_sentence(rule, problem)
      operator = rule.operator
      value = rule.field_value unless SentencesHelper::NO_VALUE_OPERATORS.include?(operator)
      written = [PermissionForge::Operators::RuleProblem.written_field(rule), operator, value]
      content_tag(:p, safe_join([pf_badge("⊘ #{pf_ui('rules.matches_nothing')}", variant: :block),
                                 content_tag(:span, pf_rule_problem_text(problem)),
                                 content_tag(:code, written.compact.join(' '), class: 'pf-mono-key')], ' '),
                  class: 'pf-sentence')
    end
  end
end
