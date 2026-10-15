require 'test_helper'

# A model with one association of every kind a rule's association path can
# name — those ActiveRecord joins and those it raises for — for the tests of
# Operators::RulePath and of what a join rule through each does. Its table is
# made here, once per test process and outside any test transaction (MySQL
# commits on DDL), so the dummy app's schema stays as it is. A top-level name,
# like the other test models: the admin only resolves those. Never give it a
# Resource row in a test that does not need one.
ActiveRecord::Schema.define do
  create_table :pf_rule_path_records, force: true do |t|
    t.string  :label
    t.integer :owner_id
    t.integer :parent_id
    t.string  :subject_type
    t.integer :subject_id
    t.integer :phantom_id
  end
  create_table :pf_rule_path_peers, id: false, force: true do |t|
    t.integer :record_id
    t.integer :peer_id
  end
end

class PfRulePathRecord < ApplicationRecord
  self.table_name = 'pf_rule_path_records'

  include PermissionForge::Concerns::PermissionScopedFindable

  # Joined.
  belongs_to :owner, class_name: 'User', optional: true
  belongs_to :parent, class_name: 'PfRulePathRecord', optional: true
  has_many :children, class_name: 'PfRulePathRecord', foreign_key: :parent_id, inverse_of: :parent, dependent: nil
  has_many :siblings, through: :parent, source: :children
  has_many :labelled_children, -> { where(label: 'mine') }, class_name: 'PfRulePathRecord', foreign_key: :parent_id,
                                                            inverse_of: false, dependent: nil
  has_one :first_child, class_name: 'PfRulePathRecord', foreign_key: :parent_id, inverse_of: false, dependent: nil
  has_and_belongs_to_many :peers, class_name: 'PfRulePathRecord', join_table: 'pf_rule_path_peers',
                                  foreign_key: :record_id, association_foreign_key: :peer_id

  # Not joined: ActiveRecord raises for each.
  belongs_to :subject, polymorphic: true, optional: true
  belongs_to :phantom, class_name: 'PfNoSuchRulePathModel', optional: true
  has_many :namesakes, ->(record) { where(label: record.label) }, class_name: 'PfRulePathRecord',
                                                                  foreign_key: :parent_id, inverse_of: false, dependent: nil
  has_many :ghosts, through: :nowhere, source: :children
  has_many :strays, class_name: 'PfRulePathRecord', foreign_key: :parent_id, inverse_of: :nowhere, dependent: nil
  # A record-dependent scope reached through a :through: the intermediate
  # association's, and the source's.
  has_many :namesake_children, through: :namesakes, source: :children
  has_many :parent_namesakes, through: :parent, source: :namesakes

  JOINED = %w[owner parent children siblings labelled_children first_child peers parent.owner children.owner
              peers.siblings].freeze
  # path => [reason, cause]
  NOT_JOINED = {
    'ownr' => [:unknown_association, nil], 'parent.ownr' => [:unknown_association, nil],
    'parent..owner' => %i[unknown_association empty_segment],
    'subject' => %i[unjoinable_association polymorphic], 'phantom' => %i[unjoinable_association class_not_loadable],
    'namesakes' => %i[unjoinable_association record_dependent_scope],
    'namesake_children' => %i[unjoinable_association record_dependent_scope],
    'parent_namesakes' => %i[unjoinable_association record_dependent_scope],
    'ghosts' => %i[unjoinable_association invalid_definition],
    'strays' => %i[unjoinable_association invalid_definition], 'parent.subject' => %i[unjoinable_association polymorphic]
  }.freeze
end
