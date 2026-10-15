require 'rails/generators'
require 'rails/generators/active_record'

module PermissionForge
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      class_option :skip_migration, type: :boolean, default: false,
                                    desc: 'Skip migration generation (for existing tables)'
      class_option :table_prefix, type: :string, default: 'permission_forge_',
                                  desc: 'Table name prefix for all permission_forge tables'
      class_option :tenant, type: :string, default: nil,
                            desc: 'Tenant model name for acts_as_tenant (e.g., Account)'
      class_option :user_id_type, type: :string, default: nil,
                                  desc: 'Column type for user ids: bigint, integer, uuid or string ' \
                                        '(default: the primary key type of the configured user model)'
      class_option :tenant_id_type, type: :string, default: nil,
                                    desc: 'Column type for the tenant column ' \
                                          '(default: the primary key type of the --tenant model)'

      KEY_TYPES = %w[bigint integer uuid string].freeze
      DETECTED_KEY_TYPES = { integer: 'bigint', uuid: 'uuid', string: 'string' }.freeze
      # Printed after an install (#print_next_steps).
      NEXT_STEPS = [
        'bin/rails db:migrate',
        'In your User model: include PermissionForge::Concerns::PermissionedUser (can_read?, permissions_hash)',
        'Mount the admin in config/routes.rb: mount PermissionForge::Engine, at: "/permissions"',
        "Admin credentials: uncomment Option A in config/initializers/permission_forge.rb\n     " \
        '(PF_ADMIN_USER, PF_ADMIN_PASSWORD), or use your own admin controller (Option B)',
        'bin/rails permission_forge:audit lists what is still open before production'
      ].freeze
      QUICK_START_URL = 'https://github.com/fetijashari/permission_forge#quick-start'.freeze

      def copy_initializer
        template 'initializer.rb.tt', 'config/initializers/permission_forge.rb'
      end

      def copy_migration
        return if options[:skip_migration]

        migration_template 'migration.rb.tt', 'db/migrate/create_permission_forge_tables.rb'
      end

      # What the files alone do not do: without a mount and credentials there
      # is no admin to open. Not printed by `rails destroy`.
      def print_next_steps
        return unless behavior == :invoke

        steps = NEXT_STEPS.drop(options[:skip_migration] ? 1 : 0)
        say "\nPermissionForge is installed. Next steps:"
        steps.each.with_index(1) { |step, number| say "  #{number}. #{step}" }
        say "  Quick Start: #{QUICK_START_URL}"
      end

      private

      def table_prefix
        options[:table_prefix]
      end

      def tenant_model
        options[:tenant].presence
      end

      # 'Account' and 'Billing::Account' both map to account_id — the column
      # name cannot carry a namespace.
      def tenant_column
        return nil unless tenant_model

        "#{tenant_model.demodulize.underscore}_id"
      end

      # Columns that store a host primary key (user ids, audit user ids, the
      # tenant id) take the type of that key. A bigint column silently
      # truncates a UUID to its leading digits, which makes different users
      # (or tenants) share permission data.
      def user_id_type
        @user_id_type ||= key_type(options[:user_id_type], PermissionForge.configuration.user_class, '--user-id-type')
      end

      def tenant_id_type
        return 'bigint' unless tenant_model

        @tenant_id_type ||= key_type(options[:tenant_id_type], tenant_model, '--tenant-id-type')
      end

      def key_type(explicit, model_name, flag)
        return validated_key_type(explicit, flag) if explicit.present?

        detected_key_type(model_name) || assume_bigint(model_name, flag)
      end

      def validated_key_type(type, flag)
        return type if KEY_TYPES.include?(type)

        raise Thor::Error, "#{flag} must be one of #{KEY_TYPES.join(', ')} (got #{type.inspect})"
      end

      # nil when the model is not loadable, has no table yet, or has a
      # composite primary key.
      def detected_key_type(model_name)
        model = model_name.to_s.safe_constantize
        return unless model.respond_to?(:columns_hash)

        primary_key = model.primary_key
        column = model.columns_hash[primary_key] if primary_key.is_a?(String)
        DETECTED_KEY_TYPES[column&.type]
      rescue ActiveRecord::ActiveRecordError
        nil
      end

      def assume_bigint(model_name, flag)
        say_status :warning, "could not read the primary key type of #{model_name}; assuming bigint. " \
                             "Pass #{flag}=uuid (or string) if its keys are not integers.", :yellow
        'bigint'
      end

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
