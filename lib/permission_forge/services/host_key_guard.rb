# frozen_string_literal: true

module PermissionForge
  module Services
    # Refuses to read permissions or write assignments when a column that
    # stores a host primary key cannot hold it.
    #
    # An integer column silently truncates a UUID or string key to its leading
    # digits ('1aaa…' and '1bbb…' both become 1), so different users would
    # share permission sets and different tenants would share permission data.
    # The install generator types these columns from the host models; this
    # guard covers installs where it could not, or that predate it.
    #
    # Checked lazily where the truncation would bite (PermissionCacheAccessor,
    # the two assignment models) rather than at boot, so `db:migrate` can still
    # run to repair an affected schema. A passing check is remembered until the
    # configuration it depends on changes.
    #
    # @api private
    class HostKeyGuard
      Mismatch = Struct.new(:table, :column, :column_type, :host, :key_type) do
        def to_s
          "#{table}.#{column} is #{column_type} but #{host}'s primary key is #{key_type}"
        end
      end

      class << self
        # @return [true]
        # @raise [PermissionForge::ConfigurationError] when a host key would be truncated
        def verify!
          signature = configuration_signature
          return true if @verified == signature

          found = mismatches
          raise PermissionForge::ConfigurationError, message(found) if found.any?

          @verified = signature
          true
        rescue *PermissionForge::DatabaseReach::READ_ERRORS
          true # schema not readable yet (before the install migration); not remembered
        end

        def reset!
          @verified = nil
        end

        # @return [Array<Mismatch>] columns that would truncate the key they store
        def mismatches
          key_columns.filter_map { |model, column, host_name| mismatch(model, column, host_name) }
        end

        private

        def configuration_signature
          config = PermissionForge.configuration
          [config.user_class, config.table_name_prefix, config.tenant_model, config.tenant_column]
        end

        # [model, column, host class name] for every column holding a host key
        # that an authorization decision depends on.
        def key_columns
          config = PermissionForge.configuration
          user_class = config.user_class
          columns = [[PermissionForge::PermissionSetUser, 'user_id', user_class],
                     [PermissionForge::PermissionSetGroupUser, 'user_id', user_class]]
          return columns unless config.tenant_enabled?

          tenant_column = config.resolved_tenant_column.to_s
          columns + tenant_scoped_models.map { |model| [model, tenant_column, config.tenant_model] }
        end

        # The audit log is tenant-scoped as well (a truncated tenant id would
        # show one tenant another's events); it is checked only once its table
        # exists, so an install that has not run the upgrade yet keeps the
        # rest of the check. Asked of the model itself, not of DatabaseReach:
        # a check that cannot look raises to verify!'s rescue, which passes
        # without remembering it (a quiet "no" would be remembered, and the
        # audit table never checked).
        def tenant_scoped_models
          models = [PermissionForge::PermissionSet, PermissionForge::PermissionSetUser,
                    PermissionForge::PermissionSetGroup, PermissionForge::PermissionSetGroupUser,
                    PermissionForge::Resource, PermissionForge::ResourceField,
                    PermissionForge::ResourceAction, PermissionForge::PermissionSetRule]
          PermissionForge::AuditEvent.table_exists? ? models + [PermissionForge::AuditEvent] : models
        end

        def mismatch(model, column, host_name)
          host = host_name.to_s.safe_constantize
          key_type = primary_key_type(host)
          column_type = PermissionForge::SchemaRead.column(model, column)&.type
          return unless column_type == :integer && key_type && key_type != :integer

          Mismatch.new(model.table_name, column, column_type, host.name, key_type)
        end

        # nil for a missing model or a composite primary key (not checked).
        def primary_key_type(host)
          return unless host.is_a?(Class) && host < ActiveRecord::Base

          key = host.primary_key
          PermissionForge::SchemaRead.column(host, key)&.type if key.is_a?(String)
        end

        def message(found)
          "PermissionForge columns cannot hold the host primary keys they store: #{found.join('; ')}. " \
            'An integer column truncates a UUID or string key to its leading digits, so different users ' \
            '(or tenants) would share permission data. Change these columns to the type of the key and ' \
            're-create the affected rows; see "UUID or string keys" in docs/migration-guide.md.'
        end
      end
    end
  end
end
