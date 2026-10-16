class User < ApplicationRecord
  include PermissionForge::Concerns::PermissionedUser
end
