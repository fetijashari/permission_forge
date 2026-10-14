require 'test_helper'

# Models that accept nested attributes, for the tests of PermitsAttributes: a
# `<assoc>_attributes` key is a nested payload only for an association the
# model accepts nested attributes for, and the dummy app's Customer and
# Supplier accept none. Both read as the dummy model's own Resource (same
# table, no type column), so they need no Resource row of their own.
#
# Customer includes PermissionScopedFindable (row rules), Supplier does not:
# the associations below point at one or the other on purpose.
class PfNestedCustomer < Customer
  # A collection on an existing table: the filter reads only the
  # association's model, never its rows.
  has_many :contacts, class_name: 'Supplier', foreign_key: :owner_id, inverse_of: false, dependent: nil
  # A belongs_to whose model has row rules; the foreign key is only a column here.
  belongs_to :sibling, class_name: 'Customer', foreign_key: :supplier_id, optional: true, inverse_of: false
  accepts_nested_attributes_for :supplier, :contacts, :sibling

  def self.name = 'Customer'
end

class PfNestedSupplier < Supplier
  has_one :primary_customer, class_name: 'Customer', foreign_key: :supplier_id, inverse_of: false, dependent: nil
  accepts_nested_attributes_for :customers, :primary_customer

  def self.name = 'Supplier'
end
