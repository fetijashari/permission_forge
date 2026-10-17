# frozen_string_literal: true

module PermissionForge
  module Admin
    # The level tables moved to PermissionForge::FieldLevel in 0.15.0 (the
    # row builder in lib/ reads them too). Internal API: the old name is
    # the same module, kept for the views and tests that spell it out.
    FieldLevel = PermissionForge::FieldLevel
  end
end
