# frozen_string_literal: true

module PermissionForge
  # Boot warnings for the three query-scoping levels (called by BootChecks;
  # each goes through Warnings.emit).
  #
  # @api private
  module QueryScopingWarnings
    module_function

    # Level 2 in :raise mode is a dev/test/CI guard; raising in production
    # turns a missed call site into an outage. Allowed, but never silently.
    def warn_unscoped_detection_raise_in_production(pf_config)
      return unless pf_config.unscoped_query_detection == :raise
      return unless pf_config.unscoped_query_detection_environments.include?('production')

      Warnings.emit(:unscoped_detection_raise_in_production,
                    'WARNING: unscoped_query_detection = :raise is enabled for production. A single unscoped ' \
                    'query will raise UnscopedQueryError in live traffic — prefer :log in production and ' \
                    ':raise in test/CI.')
    end

    # Level 1 applies filter-type rules only; join-type rules still require
    # permission_scoped. Surface that gap when both are in play.
    def warn_join_rules_not_auto_scoped(pf_config)
      return unless pf_config.auto_query_scoping_enabled?

      join_rules = PermissionForge::PermissionSetRule.join_type_rules
      return unless join_rules.exists?

      Warnings.emit(:join_rules_not_auto_scoped,
                    "auto_query_scoping is enabled but #{join_rules.count} join-type rule(s) exist. Join rules " \
                    'are NOT applied by auto-scoping — queries relying on them must go through ' \
                    'Model.permission_scoped.', severity: :security)
    rescue ActiveRecord::StatementInvalid
      # Tables don't exist yet (pre-migration)
    end

    # Level 3 needs Postgres; on any other adapter the session variable and
    # policies simply don't exist, so enabling it is a silent no-op — warn.
    # On Postgres, compare live policy digests against the current rule state
    # so edited rules can't silently diverge from the installed policies.
    def warn_rls_misconfiguration(pf_config)
      return unless pf_config.database_row_level_security

      unless PermissionForge::RLS.postgres?
        Warnings.emit(:rls_not_postgresql,
                      'WARNING: database_row_level_security is enabled but the database adapter is not ' \
                      'PostgreSQL. RLS policies cannot be enforced — row-level security falls back to ' \
                      'application-level scoping only.')
        return
      end

      warn_rls_policy_drift
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
      # Pre-boot: adapter unknown
    end

    def warn_rls_policy_drift
      stale = PermissionForge::RLS.drift_report.reject { |report| report[:in_sync] }
      return if stale.empty?

      Warnings.emit(:rls_policy_drift,
                    "RLS policies are missing or stale for table(s): #{stale.map { |report| report[:table] }.join(', ')}. " \
                    'Rule rows have changed since the last policy sync (or policies were never installed) — ' \
                    'run `rake permission_forge:rls:sync`.', severity: :security)
    rescue ActiveRecord::StatementInvalid
      # Tables don't exist yet (pre-migration)
    end
  end
end
