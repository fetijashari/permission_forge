class User < ApplicationRecord
  include PermissionForge::Concerns::PermissionedUser

  def active_for_authentication?
    !deactivated
  end

  def self.extra_fields_for_permissions
    []
  end
end
