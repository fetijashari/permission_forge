require 'test_helper'

# A single-table-inheritance family for the tests of ResourceChain: a
# protected base with a subclass and a grandchild. The table is made here,
# once per test process and outside any test transaction, so the dummy
# schema stays as it is. Top-level names, like the other test models. Rows
# for these models name no dummy model, so they disturb nothing else.
ActiveRecord::Schema.define do
  create_table :pf_sti_tickets, force: true do |t|
    t.string :type
    t.string :title
    t.string :email
    t.string :secret
    t.string :status
    t.bigint :owner_id
  end

  # A table of its own for a subclass that is not STI: no type, no status.
  create_table :pf_sti_archived_tickets, force: true do |t|
    t.string :title
    t.string :email
    t.string :secret
    t.bigint :owner_id
  end
end

class PfStiTicket < ApplicationRecord
  self.table_name = 'pf_sti_tickets'

  include PermissionForge::Concerns::PermissionScopedFindable
  include PermissionForge::Concerns::MaskedAttributes

  belongs_to :owner, class_name: 'User', optional: true
end

class PfStiBugTicket < PfStiTicket
end

class PfStiUrgentBugTicket < PfStiBugTicket
end

# A subclass with a table of its own. Rails still says base_class is
# PfStiTicket, but its rows are not PfStiTicket rows: not part of the chain.
class PfStiArchivedTicket < PfStiTicket
  self.table_name = 'pf_sti_archived_tickets'
end
