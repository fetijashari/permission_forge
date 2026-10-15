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

    # "Stauts is not a column of Customer"
    def pf_rule_problem_text(problem)
      return pf_rule_problem_cause_text(problem) if problem.cause

      model = problem.model
      pf_ui("rules.problems.#{problem.kind}", name: pf_attribute_label(model, problem.name),
                                              model: pf_resource_label(model.name))
    end

    # "Matches nothing: Stauts is not a column of Customer"
    def pf_rule_problem_line(problem)
      "#{pf_ui('rules.matches_nothing')}: #{pf_rule_problem_text(problem)}"
    end

    # A path problem with a cause (Operators::RuleProblem#cause): an empty
    # segment ("The relationship path has an empty step …"), or why the
    # relationship cannot be followed ("Subject is a polymorphic relationship
    # of Comment: …"), by RuleProblem#key.
    def pf_rule_problem_cause_text(problem)
      model = problem.model
      pf_ui("rules.problems.#{problem.key}", name: pf_attribute_label(model, problem.name),
                                             model: pf_resource_label(model.name))
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
