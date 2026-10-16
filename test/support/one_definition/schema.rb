# frozen_string_literal: true

# WP-13 — schema reads that decide "no" re-read once (plan-final.md §2 SF,
# G4 needle). A model's columns are read in one place,
# PermissionForge::SchemaRead: a column or table found missing there is read
# again from the database once before the answer is "no", so a column a
# migration added after boot (development, a rolling deploy) is seen. Any
# other `columns_hash`, `column_names.include?` / `.exclude?` / `.member?`,
# set operation on `column_names` (`names & model.column_names`,
# `names - model.column_names`) or `attribute_names.include?` would answer
# from a schema cache that may predate the migration. Loaded by
# release_readiness/one_definition_guard_test.rb with the other
# OneDefinition tables; `fixture:` is a line the needle must hit.
module OneDefinition
  SCHEMA_READ = 'lib/permission_forge/schema_read.rb'
  # `SchemaRead.column_names(...)` on the right of `&` / `-` is the one
  # reader itself; `&&` / `||` are no set operations.
  COLUMN_SET_OPERATION = /\bcolumn_names\s*[&-](?![>&])|(?<![&|])[&-]\s*(?![\w:]*SchemaRead\.)(?:[\w:@]+\.)*column_names\b/

  SCHEMA = [
    { name: "a model's columns are read through PermissionForge::SchemaRead (a missing name is read again once)",
      needle: /\bcolumns_hash\b|\bcolumn_names\.(?:include|exclude|member)\?/,
      canonical: [SCHEMA_READ],
      allowlist: [
        ['lib/permission_forge/concerns/masked_attributes.rb', /klass\.columns_hash\.each_key/,
         'defines a guarded getter for every column Rails just loaded, at include time and each time Rails defines the ' \
         'attribute methods again (define_attribute_methods: after the schema is read again): the guarded getters follow ' \
         'the columns Rails generates methods for, so a column a migration added is guarded too'],
        ['lib/permission_forge/admin/person_label.rb', /klass\.column_names\.include\?\(attr_name\)/,
         'a label reads a column raw when the user has it, else its public reader: a "no" refuses nothing, and the ' \
         'user may be any object that answers column_names (a custom user_list_resolver)'],
        ['lib/generators/permission_forge/install/install_generator.rb', /respond_to\?\(:columns_hash\)/,
         'the install generator types the host key columns once, in a fresh process'],
        ['lib/generators/permission_forge/install/install_generator.rb', /model\.columns_hash\[primary_key\]/,
         'the install generator types the host key columns once, in a fresh process']
      ],
      fixture: 'return unless model.column_names.include?(name)' },
    { name: "a set operation on a model's column names goes through PermissionForge::SchemaRead (columns_among)",
      needle: COLUMN_SET_OPERATION,
      canonical: [SCHEMA_READ],
      allowlist: [
        ['lib/permission_forge/managed_fields.rb', /column_names & ignored_fields/,
         'ManagedFields#column_names is SchemaRead.column_names (verified for a list that builds rows); the set ' \
         'operation is on that read'],
        ['lib/permission_forge/managed_fields.rb', /column_names - ignored_fields/,
         'as above (the other of the two set operations)']
      ],
      fixture: 'found = %w[email email_address] & model.column_names' },
    { name: 'an attribute-name membership test that decides "no column" goes through PermissionForge::SchemaRead',
      needle: /\battribute_names\.(?:include|exclude|member)\?/,
      canonical: [],
      allowlist: [
        ['lib/permission_forge/field_names.rb', /model\.attribute_names\.include\?\(name\)/,
         'inside SchemaRead.has? (the block is asked again after the table is read again)'],
        ['lib/permission_forge/concerns/masked_attributes.rb', /if self\.class\.attribute_names\.include\?\(name\.to_s\)/,
         'read_attribute_for_serialization on the hot path: a "no" goes to super, the public reader, which is guarded ' \
         'for a column added after the concern arrived too (MaskedAttributes.define_attribute_methods)'],
        ['lib/permission_forge/concerns/masked_attributes/validation_reads.rb', /self\.class\.attribute_names\.include\?\(name\)/,
         'picks which stored value a validator reads while it runs; a "no" reads the (guarded) method instead'],
        ['lib/permission_forge/concerns/masked_attributes/virtual_readers.rb', /attribute_names\.include\?\(name\) \|\|/,
         'the column question is asked of SchemaRead.column? on the line above; this tells an attribute-API attribute ' \
         'from a method'],
        ['lib/permission_forge/concerns/masked_attributes/virtual_readers.rb', /if attribute_names\.include\?\(name\)/,
         'picks the wrapper for a reader pf_virtual_reader? accepted (after SchemaRead.column?)']
      ],
      fixture: "ResourceField.attribute_names.include?('sensitive_acknowledged_at')" }
  ].freeze
end
