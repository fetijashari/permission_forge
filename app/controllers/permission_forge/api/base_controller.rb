# frozen_string_literal: true

module PermissionForge
  module Api
    class BaseController < PermissionForge.configuration.api_base_controller_class.constantize
      include PermissionForge::ApiAuthentication
      include PermissionForge::TenantRequired
      include PermissionForge::ParamShapes
      include PermissionForge::Api::ResponseRenderer
      include PermissionForge::Api::Pagination
      include PermissionForge::Api::SerializerResolver

      # API-safe CSRF posture. A mutating request without a valid CSRF token
      # gets an empty session and an empty cookie jar (`:null_session`), so a
      # cross-site form post from a signed-in admin's browser reaches api_auth
      # (and any host `current_user`) with no session: a session- or
      # cookie-based api_auth refuses it. Clients that authenticate with a
      # header (a token, an API key) are unaffected. `prepend: true` puts the
      # check first in the chain, before verify_api_enabled! /
      # authenticate_api_request! (ApiAuthentication) and before the host
      # base controller's own callbacks — registered after them it would
      # only empty the session once api_auth had already let the request in.
      # ActionController::API bases have no forgery protection (and no
      # cookies), so this is a no-op there.
      # Verified like the admin screens (ForgeryProtection).
      include PermissionForge::ForgeryProtection

      protect_from_forgery with: :null_session, prepend: true, **pf_forgery_strategy if respond_to?(:protect_from_forgery)

      AUDIT_SOURCE = 'api'
      # Largest id a bigint column holds; past it PostgreSQL raises instead of matching nothing.
      MAX_RECORD_ID = (2**63) - 1
      # Body attributes that refer to another record (#with_reference_id),
      # with the message of a reference that names none.
      REFERENCES = {
        permission_set_group_id: 'permission_forge.validations.permission_set.group_missing'
      }.freeze

      before_action :set_api_locale
      before_action :pf_require_tenant
      # After api_auth (a refused request records its own event).
      around_action :pf_audit_request

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: { status: 404, messages: I18n.t('permission_forge.api.errors.not_found') } }, status: :not_found
      end

      rescue_from ActiveRecord::RecordInvalid do |e|
        render_validation_errors(e.record)
      end

      # Field-keyed like a validation error (ResponseRenderer#render_input_error).
      rescue_from ActionController::ParameterMissing, ActionController::BadRequest do |e|
        render_input_error(e)
      end

      # A body Rails cannot parse (invalid JSON sent as application/json)
      # raises when params are first read — in the forgery check, before
      # api_auth — so the 400 is answered in the API's envelope instead of
      # Rails' own. A disabled API stays a 404. params[:locale] cannot be
      # read: the header decides.
      rescue_from ActionDispatch::Http::Parameters::ParseError do
        verify_api_enabled!
        next if performed?

        assign_api_locale(extract_locale_from_accept_language)
        render json: { error: { status: 400, messages: I18n.t('permission_forge.api.errors.body_unreadable') } },
               status: :bad_request
      end

      private

      # Who acts (Audit::ActorResolver: audit_actor_resolver, the signed-in
      # user, else an anonymous API client), request id, IP, the `reason`
      # body key and one correlation id per mutating request.
      def pf_audit_request(&)
        PermissionForge::Audit::RequestContext.wrap(self, source: AUDIT_SOURCE, &)
      end

      # Records a refused request so that no rollback takes it along.
      def pf_audit_refused(event, **payload)
        PermissionForge::Audit::RequestContext.refused(self, event, source: AUDIT_SOURCE, **payload)
      end

      def set_api_locale
        assign_api_locale(params[:locale] || extract_locale_from_accept_language)
      end

      # Always assign a locale (default when none/invalid) so a locale set by
      # one request can never leak into the next on a reused thread.
      def assign_api_locale(locale)
        I18n.locale = if locale.present? && api_available_locale?(locale)
                        locale
                      else
                        I18n.default_locale
                      end
      end

      def extract_locale_from_accept_language
        header = request.env['HTTP_ACCEPT_LANGUAGE']
        return nil if header.blank?

        # Split on commas, drop q-weights, take the primary subtag of each tag.
        # Matches bare tags ("en") as well as region/quality forms ("en-US;q=0.8").
        header.split(',').filter_map do |part|
          tag = part.split(';').first.to_s.strip
          primary = tag.split('-').first&.downcase
          primary if primary && api_available_locale?(primary)
        end.first
      end

      def api_available_locale?(locale)
        allowed = PermissionForge.configuration.available_locales || PermissionForge::BUNDLED_LOCALES
        Array(allowed).map(&:to_s).include?(locale.to_s)
      end

      # The record `params[param_key]` names in `scope` — the one lookup every
      # API endpoint uses. Under api_record_identifier = :id only digits name a
      # record: the database would cast '1abc', or a uuid that starts with
      # digits, to 1 and answer for another record. A NUL byte names nothing
      # (PostgreSQL raises on it). Raises RecordNotFound, rendered as a 404.
      def find_record(scope, param_key = :identifier)
        identifier = PermissionForge.configuration.api_record_identifier
        value = params[param_key].to_s
        raise ActiveRecord::RecordNotFound unless identifier_value?(identifier, value)

        scope.find_by!(identifier => value)
      end

      # `attrs` with the reference `key` (e.g. permission_set_group_id)
      # replaced by the id of the record it names in `scope`, looked up like
      # every identifier (tenant-scoped): its numeric id, or — under
      # api_record_identifier = :uuid — its uuid, the identifier the API
      # answers with. A blank value (null, "") is no reference (nil). Anything
      # else that names no record of the scope is a 422 keyed by `key`; a
      # uuid that starts with digits is never read as an id (the integer
      # column would cast "12ab…" to 12).
      #
      # @raise [ParamShapes::InvalidParam]
      def with_reference_id(attrs, key, scope)
        return attrs unless attrs.key?(key)

        value = attrs[key]
        return attrs.merge(key => nil) if value.nil? || value == ''

        attrs.merge(key => referenced_record(scope, value)&.id ||
                           raise(ParamShapes::InvalidParam.new(key, I18n.t(REFERENCES.fetch(key)))))
      end

      def referenced_record(scope, value)
        text = value.to_s if value.is_a?(String) || value.is_a?(Integer)
        return unless text

        if identifier_value?('id', text) then scope.find_by(id: text.to_i)
        elsif PermissionForge.configuration.api_record_identifier.to_s == 'uuid' && identifier_value?('uuid', text)
          scope.find_by(uuid: text)
        end
      end

      def identifier_value?(identifier, value)
        return false if value.empty? || value.include?("\0")
        return true unless identifier.to_s == 'id'

        value.match?(/\A[1-9]\d{0,18}\z/) && value.to_i <= MAX_RECORD_ID
      end

      # Looks up a host user by id within config.user_list_resolver
      # (Admin::PeopleDirectory#find), rendering a 404 (and returning nil)
      # when the id names nobody there — a missing user, someone the
      # resolver leaves out, or a value that is not a key.
      def find_host_user(user_id)
        user = PermissionForge::Admin::PeopleDirectory.new.find(user_id)
        render_not_found unless user
        user
      end

      # The person params[key] names, for a new assignment or membership,
      # within config.user_list_resolver (Admin::PeopleDirectory#find). Every
      # refusal is a 422 keyed by the parameter, so it never reads as the
      # Permission Set or the Group in the path being wrong (a 404):
      #
      # - missing, null or blank: "is missing";
      # - not one id (a list, an object, a number with a fraction, text that
      #   is not a key of the user model: "abc" for an integer key): "is not
      #   a user id";
      # - an id that names nobody the resolver lists: "names nobody who can
      #   be assigned". An unknown id and someone the resolver leaves out read
      #   the same, as in a bulk request's `skipped`.
      #
      # @raise [ParamShapes::InvalidParam]
      def requested_user(key = :user_id)
        value = params[key]
        problem = user_id_problem(value)
        user = PermissionForge::Admin::PeopleDirectory.new.find(value) unless problem
        problem ||= I18n.t('permission_forge.api.errors.user_not_found') unless user
        raise ParamShapes::InvalidParam.new(key, problem) if problem

        user
      end

      # What is wrong with a user_id before anybody is looked up, nil when
      # it is one id of the user model's key type.
      def user_id_problem(value)
        return I18n.t('permission_forge.api.errors.user_id_missing') if value.blank?
        return if (value.is_a?(String) || value.is_a?(Integer)) && PermissionForge::Admin::PeopleDirectory::Ids.cast(value).any?

        I18n.t('permission_forge.api.errors.user_id_invalid')
      end

      def authorize_action!(action, record)
        authorizer = PermissionForge.configuration.api_action_authorization
        unless authorizer
          return deny_when_authorization_required(I18n.t('permission_forge.api.errors.action_authorization_missing')) do
            audit_action_refused(action, record, hook: 'api_require_authorization')
          end
        end

        return if authorizer.call(self, action, record)

        audit_action_refused(action, record, hook: 'api_action_authorization')
        render_not_authorized(I18n.t('permission_forge.api.errors.action_not_authorized'))
      end

      # Runs the mutation authorization hook and the is_editable lock for a
      # create/update/destroy. May render a 403; callers follow with
      # `return if performed?`. Used by CrudActions and the bespoke controllers
      # so every mutation path is guarded consistently.
      # A destroy also asks the record's container (EditableLock.container_of):
      # a set in a locked group is not deleted.
      def guard_mutation!(action, record)
        authorize_action!(action, record)
        return if performed?

        enforce_editable!(record, (PermissionForge::Admin::EditableLock.container_of(record) if action == :destroy))
      end

      # Blocks a change when a record, or what it belongs to (its Resource,
      # Permission Set, or the Group of a membership — Admin::EditableLock),
      # is flagged is_editable: false: a new child of a locked parent is
      # refused like a change to the parent. Records with a nil/true flag are
      # unaffected. The refusal names the locked record.
      def enforce_editable!(*records)
        reject_locked!(PermissionForge::Admin::EditableLock.locked_record(*records))
      end

      def reject_locked!(locked)
        return unless locked

        pf_audit_refused('admin.lock_refused', record: locked)
        render json: {
          error: { status: 403, messages: I18n.t('permission_forge.api.errors.not_editable') }
        }, status: :forbidden
      end

      # config.api_assignment_authorization receives (controller, target,
      # user_ids): the Permission Set (or the Group of a membership) and an
      # Array of the people concerned cast to the user model's primary-key
      # type (Integers for integer keys) — whatever shape the request sent.
      # A refusal records the ids as requested (bounded, Audit::Refusals).
      def authorize_assignment!(permission_set, user_ids)
        authorizer = PermissionForge.configuration.api_assignment_authorization
        unless authorizer
          return deny_when_authorization_required(I18n.t('permission_forge.api.errors.assignment_authorization_missing')) do
            audit_assignment_refused(permission_set, user_ids, hook: 'api_require_authorization')
          end
        end

        return if authorizer.call(self, permission_set, PermissionForge::Admin::PeopleDirectory::Ids.cast(user_ids))

        audit_assignment_refused(permission_set, user_ids, hook: 'api_assignment_authorization')
        render_not_authorized(I18n.t('permission_forge.api.errors.assignment_not_authorized'))
      end

      # When config.api_require_authorization is on, a missing authorization lambda
      # means DENY (403) rather than the backward-compatible silent allow. This
      # prevents "authenticated == full admin" when the host wired api_auth but not
      # the per-action / assignment authorization hooks. The block records the
      # refusal. The message names the missing option (the integrator's fix),
      # unlike a lambda's denial; it carries nothing from the request.
      def deny_when_authorization_required(message)
        return unless PermissionForge.configuration.api_require_authorization

        yield
        render_not_authorized(message)
      end

      # api.auth_failed for a mutation the authorization refused. A record
      # not saved yet (create) is named by its class only.
      def audit_action_refused(action, record, hook:)
        reference = if record.respond_to?(:persisted?) && record.persisted? then { record: record }
                    elsif record then { record_type: record.class.name }
                    else {}
                    end
        pf_audit_refused('api.auth_failed', data: { 'reason' => 'action_not_authorized', 'hook' => hook, 'action' => action.to_s },
                                            **reference)
      end

      # `target` is the Permission Set, or the Permission Set Group of a
      # membership; the user ids are bounded (Audit::Refusals).
      def audit_assignment_refused(target, user_ids, hook:)
        pf_audit_refused('api.auth_failed', **PermissionForge::Audit::Refusals.assignment(target, user_ids, hook: hook))
      end
    end
  end
end
