# frozen_string_literal: true

# One fixture per kind of Operators::RuleProblem — the one taxonomy of "a rule
# that matches nothing" — shared by the taxonomy guard
# (operators/rule_problem_taxonomy_test.rb) and the admin pages that draw them
# (html/broken_rules_admin_test.rb). A kind added to RuleProblem::KINDS
# without a fixture here fails both.
#
#   include RuleProblemFixtures
#   rule = broken_rule(:unknown_operator, permission_set: set, resource: resource)
module RuleProblemFixtures
  # kind => attrs: what is written past the model to get it; refused: the
  # attribute the model refuses a new rule on (nil: accepted on save, as
  # documented — a value the column cannot hold is valid to save and matches
  # nothing); model: the Resource's model (Customer unless the kind needs
  # an association Customer does not have).
  FIXTURES = {
    missing_column: { attrs: { field_name: 'stauts' }, refused: :field_name },
    unknown_association: { attrs: { join_type: 'joins', field_accessor_path: 'ownr' }, refused: :field_accessor_path },
    unjoinable_association: { attrs: { join_type: 'joins', field_accessor_path: 'subject' }, refused: :field_accessor_path,
                              model: 'PfRulePathRecord' },
    unknown_operator: { attrs: { operator: 'regex' }, refused: :operator },
    unknown_join_type: { attrs: { join_type: 'inner', field_accessor_path: 'supplier' }, refused: :join_type },
    unknown_table: { attrs: { field_name: 'nosuch.name' }, refused: :field_name },
    unusable_value: { attrs: { field_name: 'supplier_id', field_value: '5_id' }, refused: nil }
  }.freeze

  # The model the kind's fixture is on.
  def fixture_model_name(kind)
    FIXTURES.fetch(kind).fetch(:model, 'Customer')
  end

  # A valid rule, then the kind's attributes written past the model (as a
  # rule saved before the check, or by another application on the shared
  # tables, is). Reloaded.
  def broken_rule(kind, permission_set:, resource:, **attrs)
    fixture = FIXTURES.fetch(kind)
    rule = create_permission_set_rule(permission_set: permission_set, resource: resource, name: "Rule #{kind}",
                                      field_name: 'id', field_value: '1', include_nulls: false, **attrs)
    rule.update_columns(fixture[:attrs])
    rule.reload
  end

  # An unsaved rule with the kind's attributes, for the model's validation.
  def new_broken_rule(kind, permission_set:, resource:)
    PermissionForge::PermissionSetRule.new({ uuid: SecureRandom.uuid, name: "New #{kind}", failure_message: 'No',
                                             field_name: 'id', field_value: '1', operator: 'equal', include_nulls: false,
                                             permission_set: permission_set, resource: resource }.merge(FIXTURES.fetch(kind)[:attrs]))
  end
end
