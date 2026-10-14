# frozen_string_literal: true

module PermissionForge
  module Services
    # Level 2 — DETECT (config.unscoped_query_detection = :log | :raise).
    #
    # Subscribes to sql.active_record and reports SELECT/UPDATE/DELETE
    # statements that touch a protected model's table without carrying the
    # pf_scoped annotation (added by permission_scoped, Level 1 auto-scoping,
    # and internal gem paths). INSERTs, schema/EXPLAIN queries, and anything
    # executed inside PermissionForge.without_permission_scope (which also
    # covers the gem's own internal probes) are never flagged.
    #
    #   :log   -> Rails.logger.warn with the SQL and the first app call site
    #   :raise -> PermissionForge::UnscopedQueryError
    #
    # Either way the finding is published as query.unscoped (model, table,
    # mode, call site — not the SQL, which can carry values), at most once per
    # request per table.
    #
    # Detection is environment-gated via
    # config.unscoped_query_detection_environments (default: development, test)
    # — it is a migration aid and CI guard, not a production control. The
    # notification subscriber runs synchronously on the querying thread, so
    # :raise surfaces at the offending call site.
    #
    # @api private
    class UnscopedQueryDetector
      MARKER = "/* #{PermissionForge::Concerns::PermissionScopedFindable::SCOPED_ANNOTATION} */".freeze
      STATEMENT_PATTERN = /\A\s*(?:SELECT|UPDATE|DELETE)\b/i
      IGNORED_PAYLOAD_NAMES = ['SCHEMA', 'EXPLAIN', nil].freeze

      class << self
        # Installs the sql.active_record subscriber (idempotent).
        def install!
          # rubocop:disable-next Naming/MemoizedInstanceVariableName -- @subscriber is the handle uninstall! needs
          @subscriber ||= ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
            check(payload)
          end
        end

        # Removes the subscriber (used by tests to isolate detection state).
        def uninstall!
          return unless @subscriber

          ActiveSupport::Notifications.unsubscribe(@subscriber)
          @subscriber = nil
        end

        def installed?
          !@subscriber.nil?
        end

        # Evaluates a single sql.active_record payload. Public for direct
        # testing without a live subscriber.
        def check(payload)
          return unless PermissionForge.configuration.unscoped_query_detection_active?
          return if PermissionForge.scope_suspended?
          return if IGNORED_PAYLOAD_NAMES.include?(payload[:name])

          sql = payload[:sql].to_s
          return unless sql.match?(STATEMENT_PATTERN)
          return if sql.include?(MARKER)

          table = protected_table_in(sql)
          return unless table

          report(sql, table)
        end

        private

        def protected_table_in(sql)
          PermissionForge::Concerns::PermissionScopedFindable.protected_table_names.find do |table|
            sql.match?(/\b#{Regexp.escape(table)}\b/)
          end
        end

        def report(sql, table)
          publish(table)
          message = I18n.t(
            'permission_forge.errors.unscoped_query',
            table: table,
            default: "Unscoped query on protected table '#{table}'. Use permission_scoped / find_by, " \
                     'enable auto_query_scoping, or wrap intentional access in ' \
                     'PermissionForge.without_permission_scope { }.'
          )

          raise PermissionForge::UnscopedQueryError, "#{message} SQL: #{sql}" if raise_mode?

          Rails.logger&.warn("[PermissionForge] #{message} SQL: #{truncate_sql(sql)}#{app_call_site}")
        end

        def publish(table)
          return unless PermissionForge::Audit.instrument?(PermissionForge::Audit::Runtime::UNSCOPED)

          PermissionForge::Audit::Runtime.unscoped(
            model: protected_model_for(table), table: table,
            data: { 'mode' => PermissionForge.configuration.unscoped_query_detection.to_s, 'call_site' => cleaned_backtrace_frame }
          )
        end

        def protected_model_for(table)
          PermissionForge::Concerns::PermissionScopedFindable.protected_model_names.find do |model_name|
            model_name.safe_constantize&.table_name == table
          end
        end

        def raise_mode?
          PermissionForge.configuration.unscoped_query_detection == :raise
        end

        def truncate_sql(sql)
          sql.length > 300 ? "#{sql[0, 300]}…" : sql
        end

        # The subscriber runs synchronously on the querying thread, so caller
        # still contains the app frame that triggered the query.
        def app_call_site
          frame = cleaned_backtrace_frame
          frame ? " Called from: #{frame}" : ''
        end

        def cleaned_backtrace_frame
          return caller.first unless defined?(Rails) && Rails.respond_to?(:backtrace_cleaner)

          Rails.backtrace_cleaner.clean(caller).first
        end
      end
    end
  end
end
