# frozen_string_literal: true

# The one-definition rules of the engine's decisions around rules, locks,
# assignments and the admin's effective views (CLAUDE.md "Rules"), as
# needles for release_readiness/one_definition_guard_test.rb: a decision
# re-derived outside its canonical file fails CI. Each entry is one rule;
# `canonical:` files may contain the needle, `allowlist:` entries
# ([file, line pattern, reason]) must still match (a stale entry fails).
# Another WP's rules live in its own file under test/support/one_definition/;
# the guard loads them all.
module OneDefinition
  GLOBS = %w[app/**/*.rb app/**/*.erb lib/**/*.rb lib/**/*.tt].freeze

  RULES = [
    {
      name: 'the order sets merge in (PermissionSet.in_hash_order)',
      needle: /order\(:created_at, :id\)/,
      canonical: %w[app/models/permission_forge/permission_set.rb]
    },
    {
      name: 'an ending or ended assignment (PermissionSetUser.ending_within / .ended?)',
      needle: /days\.from_now|expires_at: Time\.current\.\.|expires_at\s*[<>]=?\s*Time\.current/,
      canonical: %w[app/models/permission_forge/permission_set_user.rb],
      allowlist: [
        ['app/controllers/permission_forge/api/permission_set_users_controller.rb', /expires_at > Time\.current/,
         'refuses an end date in the past on a new assignment: a request check, not whether an assignment has ended']
      ]
    },
    {
      name: 'the review threshold (Admin::AttentionItems.stale_days)',
      needle: /admin_stale_assignment_days|DEFAULT_STALE_ASSIGNMENT_DAYS/,
      canonical: %w[lib/permission_forge/admin/attention_items.rb lib/permission_forge/configuration/admin_ui_settings.rb
                    lib/permission_forge/admin/settings_catalog.rb]
    },
    {
      name: 'a locked record (Admin::EditableLock: the chain, .permits?)',
      needle: /is_editable == false|is_editable\?|pf_locked_record\?|locked \|\| pf_locked|\|\| pf_locked\?\(/,
      canonical: %w[lib/permission_forge/admin/editable_lock.rb]
    },
    {
      name: 'a filter rule vs a join rule (PermissionSetRule.filter_join_type? / #join_rule?)',
      needle: /FILTER_JOIN_TYPES|join_type\.(blank\?|present\?|presence|nil\?|to_s ==)|== 'filter'/,
      canonical: %w[app/models/permission_forge/permission_set_rule.rb]
    },
    {
      name: 'the ambient tenant (PermissionForge.ambient_tenant_id / .ambient_tenant)',
      needle: /ActsAsTenant\.current_tenant\b(?!\s*=)/,
      canonical: %w[lib/permission_forge.rb]
    },
    {
      name: 'what happens to an unconfigured field (FiltersResponseAttributes.unconfigured_strategy)',
      needle: /UNCONFIGURED_FIELD_STRATEGIES\.fetch|UNCONFIGURED_FIELD_STRATEGIES\[/,
      canonical: %w[lib/permission_forge/services/filters_response_attributes.rb]
    },
    {
      name: 'the strictest of several field entries (ResourceChain.strictest)',
      needle: /def (self\.)?strictest\b/,
      canonical: %w[lib/permission_forge/resource_chain.rb]
    },
    {
      name: 'the Resource rows a model answers to (ResourceChain.names_for, not the name alone)',
      needle: /Resource\.where\(name: @resource(_name)?\b|\.find \{ \|r\| r\.name == @resource\.name \}/,
      canonical: [],
      allowlist: [
        ['lib/permission_forge/admin/action_across_sets.rb', /Resource\.where\(name: @resource_name\)/,
         'actions are read by the exact entry name (ResourcePermissionChecker#can?, ManagedIndex): no chain to compose']
      ]
    },
    {
      name: 'the resources that count right now (Resource.in_effect), also for "what people lose"',
      needle: /resources\.select\(&:is_active\)/,
      canonical: %w[lib/permission_forge/services/permission_hash_builder.rb lib/permission_forge/admin/effective_access.rb]
    },
    {
      name: 'the columns a rule may compare (Operators::RuleColumn.names_for)',
      needle: /columns\.reject\(&:virtual\?\)|managed_column_names\.map \{ \|name\| column/,
      canonical: %w[lib/permission_forge/admin/model_catalog.rb]
    }
  ].freeze
end
