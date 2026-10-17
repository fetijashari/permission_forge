# frozen_string_literal: true

# Review R1 #13 — "a Resource name is a model with a table" has one
# definition, PermissionForge::ModelLookup.model_for (G4 needle). Every other
# `constantize` / `safe_constantize` in app/ and lib/ resolves something
# that is not a Resource name — a configured class, a controller, the
# gem's own models, the classes that include a concern — and says so here.
module OneDefinition
  MODEL_LOOKUP = [
    { name: 'a Resource name to its model (PermissionForge::ModelLookup.model_for)',
      needle: /[.:](?:safe_)?constantize\b/,
      canonical: %w[lib/permission_forge/model_lookup.rb],
      allowlist: [
        ['lib/permission_forge/masked_models.rb', /model_name\.to_s\.safe_constantize/,
         'includes MaskedAttributes into any model a setting list or a Resource names, also before its table exists ' \
         '(boot, before the migrations): a table is not required to take the concern'],
        ['lib/permission_forge/rls.rb', /protected_model_names\.filter_map\(&:safe_constantize\)/,
         'the class names of the models that include PermissionScopedFindable, not Resource names'],
        ['lib/permission_forge/concerns/permission_scoped_findable.rb', /model_name\.safe_constantize&\.table_name/,
         'the class names of the models that include PermissionScopedFindable, not Resource names'],
        ['lib/permission_forge/services/unscoped_query_detector.rb', /model_name\.safe_constantize&\.table_name/,
         'the class names of the models that include PermissionScopedFindable, not Resource names'],
        ['lib/permission_forge/controller_actions.rb', /_controller"\.camelize\.safe_constantize/, 'a controller class, no model'],
        ['lib/permission_forge/controller_actions/mapping.rb', /name\.safe_constantize/,
         'guesses a controller\'s model; a model file that fails to load must raise (the guard never turns an error into ' \
         '"unmapped"), which ModelLookup would swallow'],
        ['lib/permission_forge/configuration.rb', /@user_class\.constantize|@user_class\.to_s\.safe_constantize|@audit_user_class\.constantize/,
         'the configured user classes'],
        ['lib/permission_forge/services/security_audit/user_model_check.rb', /user_class\.to_s\.safe_constantize|name\.safe_constantize/,
         'the configured user class and its ancestors'],
        ['lib/permission_forge/concerns/has_audit_trail.rb', /audit_user_class\.to_s\.safe_constantize/, 'the configured audit user class'],
        ['lib/permission_forge/services/host_key_guard.rb', /host_name\.to_s\.safe_constantize/, 'the configured user and tenant classes'],
        ['lib/permission_forge/services/permission_cache_clearer.rb', /tenant_model\.constantize/, 'the configured tenant model'],
        ['lib/permission_forge/admin/audit_trail.rb', /class_name\.constantize/, "the gem's own model classes (AuditTrail::TYPES)"],
        ['lib/generators/permission_forge/install/install_generator.rb', /model_name\.to_s\.safe_constantize/,
         'the install generator types host key columns from the configured user and tenant classes'],
        ['app/controllers/permission_forge/application_controller.rb', /base_controller_class\.constantize/, 'the configured base controller'],
        ['app/controllers/permission_forge/api/base_controller.rb', /api_base_controller_class\.constantize/,
         'the configured API base controller']
      ],
      fixture: 'klass = resource.name.safe_constantize' }
  ].freeze
end
