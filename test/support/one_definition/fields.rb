# frozen_string_literal: true

# WP-8a — one-definition needles for field rows (plan-final.md §2 OD, G4).
# Each entry is a StaticGuard scan: `needle` may appear only in `canonical`
# files or on an `allowlist` line (with a reason); `fixture` is a code line
# the needle must hit (the guard proves it bites). A loader iterates the
# OneDefinition::* tables (release_readiness/one_definition_fields_test.rb
# for this one).
module OneDefinition
  GEM_CODE = %w[app/**/*.rb app/**/*.erb lib/**/*.rb lib/**/*.rake].freeze
  ROW_BUILDER = 'lib/permission_forge/services/resource_field_generator/row_builder.rb'

  FIELDS = [
    { name: 'the sensitive-column matcher (gdpr_field_patterns are read in one place)',
      globs: GEM_CODE, needle: /gdpr_field_patterns/,
      canonical: %w[lib/permission_forge/sensitive_columns.rb lib/permission_forge/configuration.rb
                    lib/permission_forge/configuration/gdpr_settings.rb],
      allowlist: [['lib/permission_forge/admin/settings_catalog.rb', /d\(:gdpr_field_patterns/, 'the Settings page lists the option'],
                  ['lib/permission_forge.rb', /configuration\.gdpr_field_patterns\.keys/,
                   'gdpr_filter_parameters hands the same patterns to Rails filter_parameters: a list, not a match']],
      fixture: 'strategy = config.gdpr_field_patterns.find { |regex, _| name.match?(regex) }' },
    { name: '"readable in the clear" (ResourceField#exposes_in_clear? / .exposing_in_clear)',
      globs: GEM_CODE, needle: /where\(mask_access: false\)|read_access && !\w+\.mask_access/,
      canonical: %w[app/models/permission_forge/resource_field.rb], allowlist: [],
      fixture: 'rows = fields.where(mask_access: false)' },
    { name: 'a generated field row (ResourceFieldGenerator::RowBuilder): timestamps',
      globs: GEM_CODE, needle: /TimestampFields\.new/, canonical: [ROW_BUILDER], allowlist: [],
      fixture: 'timestamps = PermissionForge::TimestampFields.new(model, muting: false)' },
    { name: 'a generated field row (ResourceFieldGenerator::RowBuilder): the label',
      globs: GEM_CODE, needle: /label: \w+\.humanize/, canonical: [ROW_BUILDER],
      allowlist: [['lib/permission_forge/admin/change_set_parts/new_actions.rb', /resource_actions\.build\(name: key, label: key\.humanize/,
                   'a ResourceAction row (the Actions tab), not a field row']],
      fixture: 'attrs = { name: column, label: column.humanize }' },
    { name: 'a generated field row (ResourceFieldGenerator::RowBuilder): the level flags',
      globs: GEM_CODE, needle: /flags_for\(/, canonical: ['lib/permission_forge/field_level.rb', ROW_BUILDER],
      allowlist: [['lib/permission_forge/admin/change_set_parts/base.rb', /def flags_for\(level\)/,
                   'the level edits of existing rows (FieldLevels) assign flags; a new row goes through the builder'],
                  ['lib/permission_forge/admin/change_set_parts/base.rb', /FieldLevel\.flags_for\(level, muting: muting\?\)/,
                   'the level edits of existing rows (FieldLevels) assign flags; a new row goes through the builder'],
                  ['lib/permission_forge/admin/change_set_parts/field_edit.rb', /@field\.assign_attributes\(FieldLevel\.flags_for\(level, muting: @muting\)\)/,
                   'the field drawer changes the level of an existing row; a new row goes through the builder']],
      fixture: 'field.assign_attributes(FieldLevel.flags_for(level, muting: false))' },
    { name: 'the deprecated PermissionForge::Admin::SensitiveColumns is not used by the gem itself',
      globs: GEM_CODE, needle: /Admin::SensitiveColumns/, canonical: %w[lib/permission_forge/admin/sensitive_columns.rb], allowlist: [],
      fixture: 'match = PermissionForge::Admin::SensitiveColumns.new.match(key)' }
  ].freeze
end
