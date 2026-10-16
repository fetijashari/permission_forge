class Customer < ApplicationRecord
  include PermissionForge::Concerns::PermissionScopedFindable

  belongs_to :owner, class_name: 'User'
end
