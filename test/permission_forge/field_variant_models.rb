require 'test_helper'

# A model with every kind of name a field variant can be (FieldVariants):
# `owner_id` with an `owner_uuid` column, `price_cents` with a `price`
# reader, `account_id` with an `account_uuid` alias, `team_id` with only a
# `team_uuid=` writer, `region_id` with a declared virtual `region_uuid` —
# and `supplier_id`, whose `supplier_uuid` it does not have. The table is
# made here, once per test process and outside any test transaction, so the
# dummy schema stays as it is. Rows for this model name no dummy model.
ActiveRecord::Schema.define do
  create_table :pf_variant_orders, force: true do |t|
    t.string :title
    t.bigint :owner_id
    t.string :owner_uuid
    t.integer :price_cents
    t.bigint :account_id
    t.string :account_ref
    t.bigint :team_id
    t.bigint :region_id
    t.bigint :supplier_id
  end
end

class PfVariantOrder < ApplicationRecord
  self.table_name = 'pf_variant_orders'

  alias_attribute :account_uuid, :account_ref

  def self.extra_fields_for_permissions
    %w[region_uuid]
  end

  def price
    price_cents && (price_cents / 100.0)
  end

  def team_uuid=(uuid)
    self.team_id = uuid.to_s.delete_prefix('team-').to_i
  end
end
