require 'test_helper'

# A single-table-inheritance family whose subclass alone has a field
# variant (FieldVariants: `price_cents` -> `price`, a reader only
# PfStiVipOrder defines). The table is made here, once per test process and
# outside any test transaction, so the dummy schema stays as it is. Rows for
# these models name no dummy model.
ActiveRecord::Schema.define do
  create_table :pf_sti_orders, force: true do |t|
    t.string :type
    t.string :title
    t.integer :price_cents
  end
end

class PfStiOrder < ApplicationRecord
  self.table_name = 'pf_sti_orders'
end

class PfStiVipOrder < PfStiOrder
  def price
    price_cents && (price_cents / 100.0)
  end
end
