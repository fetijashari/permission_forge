# frozen_string_literal: true

module PermissionForge
  module Security
    # test_helper opts the whole suite out of api_require_authorization
    # (false) for convenience. The API security tests run on the shipped
    # default instead (true), with both authorization hooks configured to
    # allow — the setup the docs ask hosts for. A test that installs its own
    # hook replaces these.
    module ShippedApiAuthorization
      extend ActiveSupport::Concern

      included do
        setup do
          config = PermissionForge.configuration
          config.api_require_authorization = PermissionForge::Configuration.new.api_require_authorization
          config.api_action_authorization = ->(_controller, _action, _record) { true }
          config.api_assignment_authorization = ->(_controller, _target, _user_ids) { true }
        end
      end
    end
  end
end
