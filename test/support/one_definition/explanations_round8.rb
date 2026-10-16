# frozen_string_literal: true

# Field test round 8 (B#38, B#39) — one-definition needles for
# release_readiness/one_definition_guard_test.rb (G4). A person's Effective
# access row, its Why panel and the field drawer's "Explain for" word one
# decision each: why a field is at its level (FieldOutcome#reason) and the
# Resource a set acts through (FieldSource#resource_name, Outcome#muted_on).
module OneDefinition
  EXPLANATIONS_ROUND8 = [
    {
      name: 'why a person\'s field is at its level (EffectiveAccess::FieldOutcome#reason)',
      # FieldOutcome#reason asks its own attributes, not a `field.` / `outcome.`.
      needle: /\bfield\.(?:blocked_by|granted_by)\.(?:any|empty|present)\?|\boutcome\.blocked_by\.any\?/,
      canonical: [],
      fixture: '<% if outcome.blocked_by.any? %>'
    },
    {
      name: 'the Resource a set acts through on a person\'s effective access (FieldSource#resource_name, Outcome#muted_on)',
      needle: /\bpf_chain_set_name\(/,
      canonical: %w[app/helpers/permission_forge/labels_helper.rb],
      allowlist: [
        ['app/views/permission_forge/people/_effective_why.html.erb', /t\('\.flag_granted'/,
         'a flag\'s grant is a row of the resource itself (EffectiveAccess#pairs_for(granting, [name]))'],
        ['app/views/permission_forge/people/_effective_why.html.erb', /t\('\.view_all_from'/, 'as above (View All)'],
        ['app/views/permission_forge/people/_effective_why.html.erb', /t\('\.action_granted'/, 'as above (an action)']
      ],
      fixture: 'pf_chain_set_name(field.granted_by.first, res_name, field.decided_by || res_name)'
    }
  ].freeze
end
