require 'rails/generators'
require 'rails/generators/active_record'

module PermissionForge
  module Generators
    # Adds schema hardening that shipped after the initial install, for apps that
    # ran `permission_forge:install` before these guards existed.
    #
    #   bin/rails generate permission_forge:upgrade
    #
    # The table prefix defaults to the app's configured
    # PermissionForge.table_name_prefix (the initializer is loaded by
    # `rails generate`), so an app on unprefixed tables gets migrations for
    # its real tables. Pass --table-prefix to override.
    #
    # Currently: de-duplicates any (resource_id, name) collisions in
    # resource_fields (keeping the most-restrictive row) and adds the unique
    # index that new installs get by default; adds the nullable
    # resource_fields.sensitive_acknowledged_at column used by the admin UI's
    # privacy audit ("This is intended"); creates the audit_events table and
    # the review/reason columns (see add_audit_events.rb.tt).
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      class_option :table_prefix, type: :string, default: nil,
                                  desc: 'Table name prefix (default: the configured PermissionForge.table_name_prefix)'
      class_option :tenant_column, type: :string, default: nil,
                                   desc: 'Tenant column of the audit table (default: the configured tenant column, if any)'

      def copy_migration
        migration_template 'add_resource_fields_unique_index.rb.tt',
                           'db/migrate/permission_forge_add_resource_fields_unique_index.rb'
      end

      # Admin UI privacy audit: "This is intended" acknowledgements.
      def copy_admin_ui_migration
        migration_template 'add_admin_ui_columns.rb.tt',
                           'db/migrate/permission_forge_add_admin_ui_columns.rb'
      end

      # Insert-only audit log (permission_forge_audit_events) and the columns
      # the access review and acknowledgement record. Guarded: safe to re-run.
      def copy_audit_events_migration
        migration_template 'add_audit_events.rb.tt',
                           'db/migrate/permission_forge_add_audit_events.rb'
      end

      private

      def table_prefix
        options[:table_prefix] || PermissionForge.table_name_prefix.to_s
      end

      # The tenant column of the app's other tables, or nil without tenancy.
      def tenant_column
        options[:tenant_column].presence || PermissionForge.configuration.resolved_tenant_column&.to_s
      end

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
