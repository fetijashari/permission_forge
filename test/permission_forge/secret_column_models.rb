require 'test_helper'

# Models with columns that hold secrets (a password digest, tokens, an
# encrypted value) for the tests of PermissionForge::SecretColumns: a record
# rule never compares them. Their tables are made here, once per test
# process and outside any test transaction (MySQL commits on DDL), so the
# dummy app's schema stays as it is. Never give them a Resource row in a test
# that does not need one.
ActiveRecord::Schema.define do
  create_table :pf_secret_records, force: true do |t|
    t.string  :label
    t.string  :password_digest
    t.string  :api_token
    t.string  :encrypted_note
    t.string  :client_secret_hash
    t.integer :owner_id
  end
  create_table :pf_secret_notes, force: true do |t|
    t.string  :title
    t.integer :pf_secret_record_id
  end
end

class PfSecretRecord < ApplicationRecord
  self.table_name = 'pf_secret_records'

  include PermissionForge::Concerns::PermissionScopedFindable

  belongs_to :owner, class_name: 'User', optional: true
  has_many :pf_secret_notes, dependent: nil
end

class PfSecretNote < ApplicationRecord
  self.table_name = 'pf_secret_notes'

  include PermissionForge::Concerns::PermissionScopedFindable

  belongs_to :pf_secret_record, optional: true
end
