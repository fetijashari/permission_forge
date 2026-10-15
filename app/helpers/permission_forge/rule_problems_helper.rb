module PermissionForge
  # How the admin draws a record rule that matches nothing because it names a
  # column or a relationship that is not there (Operators::RuleProblem, the
  # definition the audit's missing_rule_columns and Home share): a state with
  # a glyph and a word, and why — never the rule's sentence, which would read
  # like a rule that works. SentencesHelper asks here first.
  #
  # @api private
  module RuleProblemsHelper
    # Why the rule matches nothing because it names a column or a
    # relationship that is not there (Operators::RuleProblem, the definition
    # the audit and Home share), or nil. Asked once per rule object.
    def pf_rule_problem(rule)
      @pf_rule_problems ||= {}.compare_by_identity
      return @pf_rule_problems[rule] if @pf_rule_problems.key?(rule)

      @pf_rule_problems[rule] = PermissionForge::Operators::RuleProblem.for(rule)
    end

    # A name that is not there, shown as stored (`onwer_id`, `ownr`) so the
    # admin recognises the typo; humanized it would read like a real field.
    VERBATIM_PROBLEMS = %i[missing_column unknown_association].freeze

    # "`stauts` is not a column of Customer" (a real relationship by its label).
    def pf_rule_problem_text(problem)
      model = problem.model
      name = problem.name
      verbatim = VERBATIM_PROBLEMS.include?(problem.kind)
      label = verbatim ? content_tag(:code, name, class: 'pf-mono-key') : pf_attribute_label(model, name)
      pf_ui("rules.problems.#{problem.kind}#{'_html' if verbatim}", name: label, model: pf_resource_label(model.name))
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
