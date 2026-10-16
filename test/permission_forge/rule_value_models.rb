require 'test_helper'

# A model with a column of every type a rule value is typed for, for the tests
# of Operators::ValueTyping and of what a rule selects on each database. Its
# table is made here, once per test process and outside any test transaction
# (MySQL commits on DDL), so the dummy app's schema stays as it is. A top-level
# name, like the other test models: the admin only resolves those.
ActiveRecord::Schema.define do
  postgres = connection.adapter_name.match?(/postgresql/i)
  if postgres
    # A native enum type; the table that uses it goes first.
    drop_table :pf_rule_records, if_exists: true
    execute 'DROP TYPE IF EXISTS pf_rule_mood'
    execute "CREATE TYPE pf_rule_mood AS ENUM ('calm', 'angry')"
  end
  create_table :pf_rule_records, force: true do |t|
    t.string   :label
    t.text     :notes
    t.integer  :small_count
    t.bigint   :owner_id
    t.decimal  :amount, precision: 30, scale: 10
    t.float    :ratio
    t.float    :rate, limit: 24
    t.boolean  :flag
    t.date     :born_on
    t.datetime :seen_at
    t.time     :opens_at
    t.integer  :status
    t.string   :tier
    if postgres
      t.integer :codes, array: true
      t.string  :tags, array: true
      t.text    :aliases, array: true
      t.uuid    :ref
      t.column  :code, 'char(4)'
      t.jsonb   :settings
      t.inet    :ip
      t.cidr    :net
      t.column  :mood, :pf_rule_mood
      t.interval :period
      t.macaddr :mac
    end
  end
end

class PfRuleRecord < ApplicationRecord
  self.table_name = 'pf_rule_records'

  include PermissionForge::Concerns::PermissionScopedFindable

  belongs_to :owner, class_name: 'User', optional: true
  # No columns: a polymorphic association no rule can join (RuleProblem :unjoinable_association).
  belongs_to :subject, polymorphic: true, optional: true

  enum :status, { active: 0, archived: 1, hidden: 2 }
  enum :tier, { basic: 'B', gold: 'G' }, prefix: true

  # Runs the block with other enum mappings, as after a model change.
  def self.stub_enums(mappings)
    original = defined_enums
    self.defined_enums = mappings
    yield
  ensure
    self.defined_enums = original
  end
end

# The same table through a model that leaves two columns out. The database
# still has them, so a rule that names one is still typed.
class PfRuleSlimRecord < ApplicationRecord
  self.table_name = 'pf_rule_records'
  self.ignored_columns = %w[flag status]
end

# What the tests of rule values share: the rows a rule selects, by label.
module RuleValueTestSupport
  POSTGRES = ActiveRecord::Base.connection.adapter_name.match?(/postgresql/i)
  SQLITE = ActiveRecord::Base.connection.adapter_name.match?(/sqlite/i)
  MYSQL = ActiveRecord::Base.connection.adapter_name.match?(/mysql|trilogy/i)

  def rule(**attrs)
    { name: 'Typed rule', failure_message: 'No', include_nulls: false, join_type: nil }.merge(attrs)
  end

  def scoped(model = PfRuleRecord, registry: PermissionForge::Operators::Registry, **attrs)
    PermissionForge::Services::PermissionRuleApplier.scope(
      model_class: model, rules: [rule(**attrs)], current_user: @user, operator_registry: registry
    )
  end

  # The labels of the PfRuleRecord rows a rule lets through.
  def labels(field_name, operator, field_value, **attrs)
    scoped(field_name: field_name.to_s, operator: operator, field_value: field_value, **attrs).pluck(:label).sort
  end

  def record(label, **attrs)
    PfRuleRecord.create!(label: label, **attrs)
  end

  # What stands before the table in a fully qualified column name: the schema
  # on PostgreSQL and SQLite, the database on MySQL.
  def table_qualifier
    return 'public' if POSTGRES

    SQLITE ? 'main' : PfRuleRecord.connection.current_database
  end
end
