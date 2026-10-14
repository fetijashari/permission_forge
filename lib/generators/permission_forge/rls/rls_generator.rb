require 'rails/generators'
require 'rails/generators/active_record'

module PermissionForge
  # @api private
  module Generators
    # Installs Postgres Row-Level Security for PermissionForge (Level 3).
    #
    #   bin/rails generate permission_forge:rls
    #
    # Creates a migration that enables (and forces) RLS on every protected
    # table and installs policies generated from the current rule state via
    # PermissionForge::RLS.sync!. After editing rules, re-sync with
    # `rake permission_forge:rls:sync` (drift is warned about at boot).
    #
    # Requires PostgreSQL and config.database_row_level_security = true for the
    # runtime session-variable plumbing.
    class RlsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      def check_adapter
        return if PermissionForge::RLS.postgres?

        say_status :error, 'PermissionForge RLS requires PostgreSQL — aborting.', :red
        raise Thor::Error, 'database adapter is not PostgreSQL'
      end

      def copy_migration
        migration_template 'enable_permission_forge_rls.rb.tt',
                           'db/migrate/enable_permission_forge_rls.rb'
      end

      def show_post_install
        say <<~MSG

          RLS migration created. Next steps:
            1. bin/rails db:migrate
            2. Set config.database_row_level_security = true in the initializer
            3. Wrap request/job execution: PermissionForge::RLS.with_user(user) { ... }
               (or set_user!/clear_user! in an around_action)
            4. After editing permission rules: rake permission_forge:rls:sync

          IMPORTANT: connect as a NON-superuser role without BYPASSRLS —
          superusers bypass row-level security entirely.
        MSG
      end

      private

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
