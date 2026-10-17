# frozen_string_literal: true

module PermissionForge
  module Audit
    # The registry of audit events: name → category, and for runtime (access)
    # events the group that `config.audit_runtime_events` switches storage on
    # for. Adding an event is one `register` call; an event that is not here
    # cannot be recorded or published (a typo fails loudly, not silently).
    #
    # Notification name: "<event>.permission_forge".
    #
    # @api public
    class EventCatalog
      # @api private
      class UnknownEventError < ArgumentError; end

      # `notification` is computed once: Audit.instrument asks for it on hot paths.
      # `cache`: the event sums up an operation that invalidated, cleared or
      # removed cached permissions, so its data carries the one Cache::Outcome
      # (`cache_confirmed`, `process_local`, `unconfirmed`).
      #
      # @api private
      Entry = Struct.new(:name, :category, :runtime_group, :notification, :cache, keyword_init: true) do
        # Runtime events are published by Audit.instrument and stored per group.
        def runtime? = category == 'access'

        # Whether the event's data carries a Cache::Outcome.
        def cache? = cache == true
      end

      CATEGORIES = %w[change admin system access].freeze
      RUNTIME_GROUPS = PermissionForge::Configuration::AuditSettings::RUNTIME_GROUPS

      REGISTRY_MUTEX = Mutex.new

      @entries = {}

      class << self
        # @param name [String, Symbol] e.g. 'assignment.revoked'
        # @param category [String] change, admin, system or access
        # @param runtime_group [Symbol, nil] required for access events, refused
        #   for the others
        # @param cache [Boolean] the event's data carries a Cache::Outcome (a
        #   cache-touching operation's summary; test/permission_forge/audit/cache_scope_events_test.rb
        #   runs every flagged event's operation)
        # @return [Entry]
        def register(name, category:, runtime_group: nil, cache: false)
          entry = Entry.new(name: name.to_s, category: category.to_s, runtime_group: runtime_group&.to_sym,
                            notification: "#{name}.permission_forge", cache: cache == true).freeze
          validate!(entry)
          REGISTRY_MUTEX.synchronize { @entries[entry.name] = entry }
        end

        # Removes an event from the catalog (for tests that register their own).
        # @param name [String, Symbol]
        def unregister(name)
          REGISTRY_MUTEX.synchronize { @entries.delete(name.to_s) }
        end

        # @raise [UnknownEventError] for a name that is not registered
        def fetch(name)
          @entries[name.to_s] || raise(UnknownEventError, "unknown audit event #{name.inspect}: register it with " \
                                                          'PermissionForge::Audit::EventCatalog.register')
        end

        def registered?(name)
          @entries.key?(name.to_s)
        end

        # @return [Hash{String => Entry}] a copy
        def entries
          @entries.dup.freeze
        end

        # @return [Array<String>] the names of every registered event
        def names
          @entries.keys
        end

        private

        def validate!(entry)
          raise ArgumentError, "audit event category must be one of #{CATEGORIES.join(', ')} (got #{entry.category.inspect})" \
            unless CATEGORIES.include?(entry.category)

          if entry.runtime?
            raise ArgumentError, "access event #{entry.name} needs a runtime group (#{RUNTIME_GROUPS.join(', ')})" \
              unless RUNTIME_GROUPS.include?(entry.runtime_group)
          elsif entry.runtime_group
            raise ArgumentError, "#{entry.name} is a #{entry.category} event: only access events have a runtime group"
          end
        end
      end

      # --- the catalogue of the first release ------------------------------------------

      %w[permission_set resource resource_field resource_action permission_set_rule permission_set_group]
        .product(%w[created updated destroyed]).each { |model, verb| register("#{model}.#{verb}", category: 'change') }

      %w[permission_set.cloned permission_set_group.cloned assignment.granted assignment.changed assignment.revoked assignment.reviewed
         group_membership.added group_membership.changed group_membership.removed field.sensitive_acknowledged]
        .each { |name| register(name, category: 'change') }

      %w[erasure.performed consent.withdrawn cleanup.expired_assignments cache.cleared cache.settled]
        .each { |name| register(name, category: 'system', cache: true) }
      %w[audit.purged audit.settings_observed report.generated].each { |name| register(name, category: 'system') }

      %w[admin.effective_access_viewed audit.viewed audit.exported admin.auth_failed api.auth_failed admin.lock_refused]
        .each { |name| register(name, category: 'admin') }

      {
        'access.denied' => :denied, 'action.denied' => :denied,
        'rule.bypassed' => :bypass, 'query.unscoped' => :bypass, 'field.unmasked_without_user' => :bypass,
        'field.access' => :field_read,
        'params.filtered' => :params_filtered, 'write.masked_skipped' => :params_filtered,
        'permissions.rebuilt' => :cache, 'permissions.invalidated' => :cache
      }.each { |name, group| register(name, category: 'access', runtime_group: group) }
    end
  end
end
