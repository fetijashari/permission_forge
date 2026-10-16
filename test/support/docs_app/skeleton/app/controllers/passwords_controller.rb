# The generator's password reset, reduced to the page the sign-in form links
# to (no mailer in the docs app). Excluded from the guard with `sessions`.
class PasswordsController < ApplicationController
  allow_unauthenticated_access

  def new
  end
end
