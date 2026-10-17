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
#   encrypts nothing;
# - PfEncryptedOwner / PfEncryptedLink / PfEncryptedItem: `has_many :items,
#   through: :links`, where only the join table's model encrypts (`note`):
#   a rule on the path `items` joins `pf_encrypted_links`, a table no model
#   along its path is on (review of the round-7 fixes, P0-1);
# - PfEncryptedScopedOwner: the owners table again, with a default scope
#   that joins the links, so the applier's query joins a table neither the
#   rule's path nor its own join brings in.
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
  create_table :pf_encrypted_owners, force: true do |t|
    t.string :title
  end
  create_table :pf_encrypted_links, force: true do |t|
    t.bigint :owner_id
    t.bigint :item_id
    t.text   :note
  end
  create_table :pf_encrypted_items, force: true do |t|
    t.string :title
    t.bigint :owner_id
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

class PfEncryptedLink < ApplicationRecord
  self.table_name = 'pf_encrypted_links'

  encrypts :note
  belongs_to :owner, class_name: 'PfEncryptedOwner', optional: true
  belongs_to :item, class_name: 'PfEncryptedItem', optional: true
end

class PfEncryptedItem < ApplicationRecord
  self.table_name = 'pf_encrypted_items'
end

class PfEncryptedOwner < ApplicationRecord
  self.table_name = 'pf_encrypted_owners'

  include PermissionForge::Concerns::PermissionScopedFindable

  has_many :links, class_name: 'PfEncryptedLink', foreign_key: :owner_id, inverse_of: :owner
  has_many :items, through: :links
end

class PfEncryptedScopedOwner < ApplicationRecord
  self.table_name = 'pf_encrypted_owners'

  include PermissionForge::Concerns::PermissionScopedFindable

  default_scope { joins(:links) }
  has_many :links, class_name: 'PfEncryptedLink', foreign_key: :owner_id, inverse_of: false
  has_many :own_items, class_name: 'PfEncryptedItem', foreign_key: :owner_id, inverse_of: false
end
