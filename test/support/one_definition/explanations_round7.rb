# frozen_string_literal: true

# Round 7 P3 (EX — explanations come from the deciding definition) —
# one-definition needles for release_readiness/one_definition_guard_test.rb
# (G4). Each `fixture:` is a line the needle must hit (the negative fixture,
# proven by the guard's "every fixture line is a hit").
module OneDefinition
  EXPLANATIONS_ROUND7 = [
    {
      name: 'an hour window: set, overnight, broken (ActivationConditions::HoursWindow)',
      needle: /\b(?:from|to|allowed_hours_(?:start|end)\)?)\s*(?:<=|>=|<|>|==|!=)\s*
                (?:from\b|to\b|hour\(:allowed_hours_(?:start|end)\)|(?:set\.)?allowed_hours_(?:start|end)\b)|
                allowed_hours_start\.present\?\s*&&/x,
      canonical: %w[lib/permission_forge/activation_conditions.rb],
      allowlist: [
        ['lib/permission_forge/admin/change_set.rb', /from == to \|\|/, 'an edit\'s value before and after (from / to), not an hour'],
        ['lib/permission_forge/admin/editable_lock.rb', /return nil if to == from/, 'two end dates of an assignment, not an hour']
      ],
      fixture: '<% if hours_on && to <= from %>'
    },
    {
      name: 'an IP entry is an address (ActivationConditions.ip_range / .request_address)',
      needle: /\bIPAddr\.new\b/,
      canonical: %w[lib/permission_forge/activation_conditions.rb],
      allowlist: [
        ['lib/permission_forge/operators/value_casters/postgresql_types.rb', /IPAddr\.new/,
         'types a rule value for an inet / cidr column (ValueTyping), not an activation condition']
      ],
      fixture: 'IPAddr.new(value)'
    },
    {
      name: 'the operators that add the NULL rows under include_nulls (Operators::Registry::NULL_INCLUDING)',
      needle: /%w\[equal not_equal in not_in\]/,
      canonical: [],
      fixture: 'NULLABLE = %w[equal not_equal in not_in].freeze'
    },
    {
      name: 'the operators that take no value (Operators::Validations::VALUELESS) and the list shapes (ValueTyping::SHAPES)',
      needle: /%w\[is_null is_not_null\]|%w\[in not_in\]/,
      canonical: [],
      fixture: 'LIST_OPERATORS = %w[in not_in].freeze'
    }
  ].freeze
end
