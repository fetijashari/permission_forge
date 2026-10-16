# frozen_string_literal: true

require_relative '../html/admin_test_case'

module PermissionForge
  module Audit
    # Field test round 7 (E#70, critique 23): text the gem writes into an
    # event itself was English stored as data — the reason
    # ExpiredAssignmentCleaner records ("expired": "Arsyeja: expired" on the
    # Albanian log), the label of an API client nobody names ("API client"),
    # the settings observer's actor ("boot"). They are codes now
    # (Audit::ReasonCodes, Audit::ActorCodes), rendered from the locale by
    # `pf_audit_reason` and Admin::ActorLabel; a reason an admin typed is
    # shown as typed.
    class GeneratedCodesTest < Html::AdminTestCase
      test 'the cleaner records the reason code, and the event page, the log and the person tab render it translated' do
        expired = create_permission_set_user(user: @bo, permission_set: @set)
        expired.update_columns(expires_at: 1.day.ago)
        Services::ExpiredAssignmentCleaner.call
        event = AuditEvent.where(event: 'cleanup.expired_assignments').order(:id).last
        assert_equal ReasonCodes::EXPIRED, event.reason

        translated = I18n.t('permission_forge.audit_log.reason_codes.expired', locale: :sq)
        assert_not_equal 'expired', translated

        get pf("/audit/#{event.uuid}"), params: { locale: 'sq' }
        assert_response :success
        assert_select 'dd', text: translated

        get pf('/audit'), params: { locale: 'sq' }
        assert_response :success
        assert_select '.pf-audit-event__reason', text: /#{Regexp.escape(translated)}/
        assert_select '.pf-audit-event__reason', text: /\bexpired\b/, count: 0

        Context.with(reason: ReasonCodes::EXPIRED) { create_permission_set_user(user: @bo, permission_set: create_permission_set) }
        get pf("/people/#{@bo.id}"), params: { tab: 'audit', locale: 'sq' }
        assert_response :success
        assert_includes response.body, I18n.t('permission_forge.audit_log.reason_inline', reason: translated, locale: :sq)
        assert_not_includes response.body, I18n.t('permission_forge.audit_log.reason_inline', reason: 'expired', locale: :sq)
      end

      test 'a reason somebody typed is shown as typed' do
        PermissionForge.with_audit_actor(label: 'ops') do
          Context.with(reason: 'left the team') { @assignment.destroy! }
        end
        event = AuditEvent.where(event: 'assignment.revoked').order(:id).last

        get pf("/audit/#{event.uuid}"), params: { locale: 'sq' }
        assert_select 'dd', text: 'left the team'
      end

      test 'an API client nobody names and the boot are stored as codes and named in the locale' do
        assert_equal ActorCodes::API_CLIENT, ActorResolver::FALLBACKS.fetch('api').call.label

        {
          ['api', ActorCodes::API_CLIENT] => I18n.t('permission_forge.audit_log.actor_codes.api_client', locale: :sq),
          ['api', 'API client'] => I18n.t('permission_forge.audit_log.actor_codes.api_client', locale: :sq),
          ['system', ActorCodes::BOOT] => I18n.t('permission_forge.audit_log.actor_codes.boot', locale: :sq)
        }.each do |(type, label), expected|
          event = AuditEvent.new(actor_type: type, actor_label: label)

          assert_equal expected, I18n.with_locale(:sq) { Admin::ActorLabel.for(event) }, label
        end
        person = I18n.with_locale(:sq) { Admin::ActorLabel.for(AuditEvent.new(actor_type: 'user', actor_label: 'boot')) }

        assert_equal 'boot', person, 'a person called boot is a person: a code only for its kind of actor'
      end

      test 'the settings observer stores the boot code' do
        event = SettingsObserver.call

        assert_equal %w[system boot], [event.actor_type, event.actor_label]
        assert_equal ActorCodes::BOOT, event.actor_label
      end
    end
  end
end
