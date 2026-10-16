# A host model with an encrypted column (ActiveRecord::Encryption; the keys
# are in config/environments/test.rb) and an enum: two attribute kinds whose
# getter does not return the stored bytes. The shape every enforcement path
# is checked on in test/permission_forge/host_shapes_test.rb. Rows named
# after it never touch User or Account.
class PfEncryptedNote < ApplicationRecord
  include PermissionForge::Concerns::PermissionScopedFindable

  encrypts :body
  enum :status, { draft: 0, published: 1 }

  belongs_to :owner, class_name: 'User', optional: true
end
