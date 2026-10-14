class Supplier < ApplicationRecord
  has_many :customers
  belongs_to :owner, class_name: 'User', foreign_key: 'owner_id', optional: true
end
