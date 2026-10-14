# frozen_string_literal: true

module PermissionForge
  module Audit
    # The audit boot warnings, written by the engine once the database is
    # reachable. The missing-table warning is logged by Audit (once per
    # process, by Audit.verify_table!) with the text of .missing_table; this
    # adds auditing switched off and one shared login for every change.
    #
    # @api private
    module BootWarnings
      def self.call(configuration = PermissionForge.configuration)
        PermissionForge::Audit.verify_table!

        if configuration.audit_events == false
          Rails.logger&.warn '[PermissionForge] SECURITY warning: audit_events is false, so permission changes ' \
                             'are not recorded. Set config.audit_events = :auto unless another system records them.'
        end

        return unless configuration.http_basic_auth_enabled && configuration.audit_actor_resolver.nil?

        Rails.logger&.warn '[PermissionForge] The admin UI uses HTTP Basic auth and audit_actor_resolver is not ' \
                           'set: every change is attributed to the shared login. Set ' \
                           'config.audit_actor_resolver to return the signed-in admin.'
      end

      # The missing-table warning (Audit logs it once per process). Its
      # remedy depends on the app: a migration of the gem's that creates the
      # table is there (a fresh install, or an upgrade already generated) and
      # has not run — db:migrate; none — the install predates the audit log,
      # and the upgrade generator writes it (on a fresh install it would
      # duplicate migrations).
      #
      # @param table [String] the audit events table name
      # @return [String]
      def self.missing_table(table)
        remedy = if audit_migration_present?
                   'the pending migration has run (bin/rails db:migrate)'
                 else
                   'its migration is generated and run (bin/rails generate permission_forge:upgrade, then bin/rails db:migrate)'
                 end
        "[PermissionForge] audit_events is :auto but the table '#{table}' was not found: no audit events are " \
          "recorded until #{remedy}. Changes still work."
      end

      # @return [Boolean] whether a permission_forge migration in the app's
      #   migration paths creates the audit events table
      def self.audit_migration_present?
        Array(ActiveRecord::Migrator.migrations_paths).any? do |path|
          Dir.glob(File.join(path.to_s, '*permission_forge*.rb')).any? { |file| File.read(file).include?('audit_events') }
        end
      rescue SystemCallError
        false
      end
      private_class_method :audit_migration_present?
    end
  end
end
