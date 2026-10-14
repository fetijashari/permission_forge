module PermissionForge
  # Asks `config.admin_assignment_authorization` before a change to who holds
  # a Permission Set or belongs to a Permission Set Group — in the HTML admin
  # and in the API (there after `api_assignment_authorization`, which keeps
  # its own signature). Segregation of duties lives in the lambda, e.g. no
  # self-assignment:
  #
  #   config.admin_assignment_authorization = lambda { |controller, target, user_ids, action|
  #     admin = PermissionForge.current_user
  #     admin&.admin? && !user_ids.include?(admin.id)
  #   }
  #
  # The lambda receives (controller, target, user_ids, action):
  #   controller — the admin or API controller handling the request
  #   target     — the PermissionForge::PermissionSet or ::PermissionSetGroup
  #   user_ids   — Array of the people concerned, cast to the user model's
  #                primary-key type (Integers for bigint keys)
  #   action     — one of ACTIONS
  # A truthy answer allows; nil (no lambda) allows everything. A refused
  # request changes nothing, so it writes no change event; a raising lambda
  # raises (the request fails, nothing changes).
  #
  # @api private
  module AssignmentAuthorization
    # :grant / :revoke a Permission Set, :change_expiry of an assignment,
    # :review (access review "Keep"), :add_member / :remove_member of a group.
    ACTIONS = %i[grant revoke change_expiry review add_member remove_member].freeze

    private

    # @param target [PermissionForge::PermissionSet, PermissionForge::PermissionSetGroup]
    # @param user_ids [Array, Object] the people concerned
    # @param action [Symbol] one of ACTIONS
    # @return [Boolean]
    def pf_assignment_allowed?(target, user_ids, action)
      raise ArgumentError, "unknown assignment action #{action.inspect}" unless ACTIONS.include?(action)

      hook = PermissionForge.configuration.admin_assignment_authorization
      return true unless hook

      hook.call(self, target, pf_cast_user_ids(user_ids), action) ? true : false
    end

    # HTML admin: true (after redirecting with an alert) when any of the
    # targets is refused, so the caller returns before changing anything.
    # The refusal is recorded (admin.auth_failed).
    def pf_assignment_refused?(targets, user_ids, action, path)
      refused = Array(targets).find { |target| !pf_assignment_allowed?(target, user_ids, action) }
      return false unless refused

      pf_audit_assignment_refusal('admin.auth_failed', refused, user_ids, action)
      redirect_to path, alert: t('permission_forge.flash.assignment_not_authorized')
      true
    end

    # API: true (after rendering a 403) when the target is refused. The
    # refusal is recorded (api.auth_failed).
    def pf_assignment_refused_api?(target, user_ids, action)
      return false if pf_assignment_allowed?(target, user_ids, action)

      pf_audit_assignment_refusal('api.auth_failed', target, user_ids, action)
      render_not_authorized(I18n.t('permission_forge.api.errors.assignment_not_authorized'))
      true
    end

    # The locked set that refuses a change to its holders because the change
    # widens access — adding to a granting set, removing from a Muting one,
    # an end date moved the matching way (Admin::EditableLock.widening_lock);
    # nil when the change may go ahead.
    #
    # @param change [Symbol] :grant, :revoke or :change_expiry (with from:/to:)
    # @return [PermissionForge::PermissionSet, nil]
    def pf_widening_lock(permission_set, change, **expiry)
      PermissionForge::Admin::EditableLock.widening_lock(permission_set, change, **expiry)
    end

    # HTML admin: true (after redirecting with the lock's alert and recording
    # admin.lock_refused) when `locked` (a #pf_widening_lock answer) is a set.
    def pf_widening_refused?(locked, path)
      return false unless locked

      alert = locked.is_muting ? t('permission_forge.flash.locked_widening_muting') : t('permission_forge.flash.locked_widening')
      pf_reject_locked!(locked, path, alert: alert)
    end

    # pf_audit_refused: the including base controller's (HTML or API).
    def pf_audit_assignment_refusal(event, target, user_ids, action)
      payload = PermissionForge::Audit::Refusals.assignment(target, user_ids, action: action,
                                                                              hook: 'admin_assignment_authorization')
      pf_audit_refused(event, **payload)
    end

    def pf_cast_user_ids(user_ids)
      PermissionForge::Admin::PeopleDirectory::Ids.cast(user_ids)
    end
  end
end
