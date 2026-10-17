# frozen_string_literal: true

# Review round 7 (E#73) — "this column holds ciphertext" (an attribute
# declared with `encrypts`) has one definition,
# PermissionForge::EncryptedAttributes (G4 needle): the rule check
# (Operators::RuleColumn#encrypted?, ValueTyping), the people search, bulk
# matching and person labels all ask it. Rails' readers are asked nowhere else.
module OneDefinition
  ENCRYPTED_ATTRIBUTES = [
    { name: 'which columns hold ciphertext (PermissionForge::EncryptedAttributes)',
      needle: /\.(?:deterministic_)?encrypted_attributes\b/,
      canonical: %w[lib/permission_forge/encrypted_attributes.rb],
      allowlist: [],
      fixture: 'Array(klass.encrypted_attributes).include?(name.to_sym)' }
  ].freeze
end
