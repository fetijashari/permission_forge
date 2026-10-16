require 'test_helper'

# Encrypted columns a rule reaches other than by its own model's name (review
# of round 7, P1-1 and P2-2), for the tests of what such a rule does. Their
# tables are made here, once per test process and outside any test
# transaction (MySQL commits on DDL), so the dummy app's schema stays as it
# is. Top-level names, like the other test models: the admin only resolves
# those.
#
# - PfEncryptedTwin: a self-referential association, so a rule's join gives
#   its own table an alias (`twins_pf_encrypted_twins`);
# - PfEncryptedStiNote / PfEncryptedStiSecret: single-table inheritance where
#   only the subclass encrypts `body` (the base class's own
#   `encrypted_attributes` is nil), and PfEncryptedStiMemo, a sibling that
#   encrypts nothing.
ActiveRecord::Schema.define do
  create_table :pf_encrypted_twins, force: true do |t|
    t.string :title
    t.text   :body
    t.bigint :twin_id
  end
  create_table :pf_encrypted_sti_notes, force: true do |t|
    t.string :type
    t.string :title
    t.text   :body
  end
end

class PfEncryptedTwin < ApplicationRecord
  self.table_name = 'pf_encrypted_twins'

  include PermissionForge::Concerns::PermissionScopedFindable

  encrypts :body
  belongs_to :twin, class_name: 'PfEncryptedTwin', optional: true
end

class PfEncryptedStiNote < ApplicationRecord
  self.table_name = 'pf_encrypted_sti_notes'

  include PermissionForge::Concerns::PermissionScopedFindable
end

class PfEncryptedStiSecret < PfEncryptedStiNote
  encrypts :body
end

class PfEncryptedStiMemo < PfEncryptedStiNote
end
