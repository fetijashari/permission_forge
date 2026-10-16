# frozen_string_literal: true

# WP-12 (EX — explanations come from the deciding predicate) — one-definition
# needles for release_readiness/one_definition_guard_test.rb (G4).
module OneDefinition
  EXPLANATIONS = [
    {
      name: 'the fix a rule that matches nothing names (Operators::RuleProblem#remedy, by kind)',
      needle: /\.path\? \?|problem_(field|path)\b/,
      canonical: []
    }
  ].freeze
end
