# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # The audit event log ({PermissionForge::Audit}): is it recording, can
      # its actors be trusted, and are the failure settings strict enough.
      # Event queries use the indexed event / actor_type / occurred_at columns
      # and follow the tenant scoping of the AuditEvent model like any other.
      class AuditTrailCheck < BaseCheck
        RULES = %i[
          table_missing audit_off shared_basic_auth anonymous_api unknown_actors self_granted
          default_runtime_events hook_failures_only_logged change_failures_not_raised kept_forever
        ].freeze

        UNKNOWN_ACTOR_DAYS = 30
        SUBJECT_LIMIT = 10
        SELF_GRANT_SCAN_LIMIT = 5000

        def call
          RULES.filter_map { |rule| send(rule) }
        end

        private

        def audit_events = PermissionForge::AuditEvent

        # true, false, or nil when the database could not be asked.
        def table?
          return @table if defined?(@table)

          @table = audit_events.table_exists?
        rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid
          @table = nil
        end

        def table_missing
          return if configuration.audit_events == false || table? != false

          finding(:high, :audit_table_missing, 'The audit events table is missing',
                  "audit_events is #{configuration.audit_events.inspect} but the table #{audit_events.table_name} " \
                  "does not exist, so #{missing_table_effect}. Run bin/rails generate permission_forge:upgrade " \
                  'and migrate.')
        end

        # :auto records nothing without the table; true tries every time.
        def missing_table_effect
          return 'no permission change is recorded (changes still go through)' unless configuration.audit_events == true
          return 'every permission change fails (audit_change_failure_strategy :raise)' if
            configuration.audit_change_failure_strategy == :raise

          'every permission change goes through unrecorded (audit_change_failure_strategy ' \
            ":#{configuration.audit_change_failure_strategy})"
        end

        def audit_off
          return unless configuration.audit_events == false

          finding(:high, :audit_off, 'The audit event log is switched off',
                  'audit_events is false: nobody can later tell who granted, changed or revoked access. Set it ' \
                  'to :auto (or true) unless another system records these changes.')
        end

        def shared_basic_auth
          return unless configuration.http_basic_auth_enabled && configuration.audit_actor_resolver.nil?

          finding(:medium, :audit_shared_basic_auth, 'Admin changes can be attributed to one shared login',
                  'The admin UI uses HTTP Basic auth and audit_actor_resolver is not set, so when ' \
                  'current_user_resolver finds nobody in an admin request, its events name the shared ' \
                  'username, not a person. Set audit_actor_resolver to return the signed-in admin.')
        end

        def anonymous_api
          return unless configuration.api_enabled && configuration.audit_actor_resolver.nil?

          finding(:medium, :audit_anonymous_api, 'API changes can be recorded as an anonymous API client',
                  'The JSON API is enabled and audit_actor_resolver is not set, so when current_user_resolver ' \
                  'finds nobody in an API request (a token or API key), its events name an anonymous ' \
                  '"API client", not the caller. Set audit_actor_resolver to return the token, key or user.')
        end

        def unknown_actors
          return unless table?

          count = audit_events.where(category: 'change', actor_type: 'unknown', occurred_at: UNKNOWN_ACTOR_DAYS.days.ago..)
                              .count
          return if count.zero?

          finding(:medium, :audit_unknown_actors,
                  "#{count} #{count == 1 ? 'change' : 'changes'} in #{UNKNOWN_ACTOR_DAYS} days " \
                  "#{count == 1 ? 'has' : 'have'} no known actor",
                  'Changes were made where no user, API caller or system label was available (a console, job or ' \
                  'script outside PermissionForge.with_audit_actor). Wrap such work in with_audit_actor, or set ' \
                  'current_user_resolver / audit_actor_resolver.')
        end

        def self_granted
          return unless table?

          grants = self_grant_events
          return if grants.empty?

          held = PermissionForge::PermissionSetUser.active_assignments.where(id: grants.map(&:first)).pluck(:user_id).uniq
          return if held.empty?

          finding(:high, :audit_self_granted,
                  "#{people_label(held.size)} #{held.size == 1 ? 'holds' : 'hold'} access they granted to themselves",
                  'The assignment.granted event names the same person as grantor and recipient. Confirm each ' \
                  'was approved by someone else, and restrict who may assign sets (admin_assignment_authorization).',
                  items: held.first(SUBJECT_LIMIT).map { |id| "user #{id}" })
        end

        # [assignment id, subject id] of grants whose actor is their subject.
        def self_grant_events
          table = audit_events.arel_table
          audit_events.where(event: 'assignment.granted', actor_type: 'user',
                             record_type: PermissionForge::PermissionSetUser.base_class.name)
                      .where(table[:actor_id].eq(table[:subject_user_id]))
                      .order(occurred_at: :desc).limit(SELF_GRANT_SCAN_LIMIT).pluck(:record_id, :subject_user_id)
                      .map { |record_id, subject| [record_id.to_i, subject] }
        end

        def default_runtime_events
          groups = Array(configuration.audit_runtime_events)
          return unless (groups - [:denied]).empty?
          return no_runtime_events if groups.empty?

          finding(:info, :audit_runtime_default, 'Only denied access is recorded at runtime',
                  'audit_runtime_events holds just :denied, so reads of masked fields, rule bypasses and cache ' \
                  'rebuilds leave no event. Add groups (:bypass, :field_read, ...) if you must show who saw what.')
        end

        def no_runtime_events
          finding(:info, :audit_runtime_default, 'No runtime events are stored',
                  'No runtime events are stored (audit_runtime_events is empty): denied access, reads of masked ' \
                  'fields, rule bypasses and cache rebuilds leave no event (they are still published as ' \
                  'notifications). Add :denied at least, and other groups if you must show who saw what.')
        end

        def hook_failures_only_logged
          return unless configuration.audit_hook_failure_strategy == :log

          finding(:low, :audit_hook_failures_logged, 'Audit hook failures are only logged',
                  'audit_hook_failure_strategy is :log: a failing subscriber or runtime event store is not ' \
                  'handed to Rails.error. Use :report (default) so it reaches your error tracker.')
        end

        def change_failures_not_raised
          return if configuration.audit_change_failure_strategy == :raise

          finding(:medium, :audit_changes_unrecorded, 'A permission change can go through without its audit event',
                  "audit_change_failure_strategy is :#{configuration.audit_change_failure_strategy}: when the event " \
                  'cannot be written the change still succeeds and the record is lost. Use :raise (default).')
        end

        def kept_forever
          return unless configuration.audit_retention_period.nil?

          finding(:info, :audit_kept_forever, 'Audit events are kept forever',
                  'audit_retention_period is nil. Confirm this matches your retention policy, or set a period ' \
                  'so the purge service can remove older events.')
        end
      end
    end
  end
end
