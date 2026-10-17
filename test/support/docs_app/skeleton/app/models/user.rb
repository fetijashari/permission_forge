class User < ApplicationRecord
  include PermissionForge::Concerns::PermissionedUser

  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }
end
