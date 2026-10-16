# A host model shaped like none of the others: namespaced (its Resource name
# is "Billing::Invoice"), on a uuid primary key, with no integer id. The
# shape every enforcement path is checked on in
# test/permission_forge/host_shapes_test.rb. Rows named after it never touch
# User or Account.
module Billing
  class Invoice < ApplicationRecord
    include PermissionForge::Concerns::PermissionScopedFindable

    self.table_name = 'billing_invoices'
    self.primary_key = 'uuid'

    belongs_to :owner, class_name: 'User', optional: true

    before_create { self.uuid ||= SecureRandom.uuid }
  end
end
