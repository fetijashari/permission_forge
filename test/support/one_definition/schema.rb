# frozen_string_literal: true

# WP-13 — schema reads that decide "no" re-read once (plan-final.md §2 SF,
# G4 needle). A model's columns are read in one place,
# PermissionForge::SchemaRead: a column or table found missing there is read
# again from the database once before the answer is "no", so a column a
# migration added after boot (development, a rolling deploy) is seen. Any
# other `columns_hash` / `column_names.include?` / `.exclude?` would answer
# from a schema cache that may predate the migration. Loaded by
# release_readiness/one_definition_guard_test.rb with the other
# OneDefinition tables; `fixture:` is a line the needle must hit.
module OneDefinition
  SCHEMA_READ = 'lib/permission_forge/schema_read.rb'

  SCHEMA = [
    { name: "a model's columns are read through PermissionForge::SchemaRead (a missing name is read again once)",
      needle: /\bcolumns_hash\b|\bcolumn_names\.(?:include|exclude)\?/,
      canonical: [SCHEMA_READ],
      allowlist: [
        ['lib/permission_forge/concerns/masked_attributes.rb', /columns_hash\.each_key/,
         'defines a guarded getter for every column the model has when the concern arrives (ignored columns excluded), ' \
         'captured at include time as the comment there says: a list read, it decides no refusal'],
        ['lib/permission_forge/admin/person_label.rb', /klass\.column_names\.include\?\(attr_name\)/,
         'a label reads a column raw when the user has it, else its public reader: a "no" refuses nothing, and the ' \
         'user may be any object that answers column_names (a custom user_list_resolver)'],
        ['lib/generators/permission_forge/install/install_generator.rb', /respond_to\?\(:columns_hash\)/,
         'the install generator types the host key columns once, in a fresh process'],
        ['lib/generators/permission_forge/install/install_generator.rb', /model\.columns_hash\[primary_key\]/,
         'the install generator types the host key columns once, in a fresh process']
      ],
      fixture: 'return unless model.column_names.include?(name)' }
  ].freeze
end
