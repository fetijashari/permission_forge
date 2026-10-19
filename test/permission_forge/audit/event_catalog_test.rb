# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Audit
    class EventCatalogTest < ActiveSupport::TestCase
      CHANGE_EVENTS = %w[permission_set resource resource_field resource_action permission_set_rule permission_set_group]
                      .product(%w[created updated destroyed]).map { |model, verb| "#{model}.#{verb}" } +
                      %w[permission_set.cloned assignment.granted assignment.changed assignment.revoked assignment.reviewed
                         group_membership.added group_membership.removed field.sensitive_acknowledged]
      SYSTEM_EVENTS = %w[erasure.performed consent.withdrawn cleanup.expired_assignments cache.cleared audit.purged
                         audit.settings_observed report.generated].freeze
      ADMIN_EVENTS = %w[admin.effective_access_viewed audit.viewed audit.exported admin.auth_failed api.auth_failed
                        admin.lock_refused].freeze
      ACCESS_EVENTS = %w[access.denied action.denied rule.bypassed field.access params.filtered write.masked_skipped
                         permissions.rebuilt permissions.invalidated query.unscoped field.unmasked_without_user].freeze

      test 'every event of the first release is registered under its category' do
        { 'change' => CHANGE_EVENTS, 'system' => SYSTEM_EVENTS, 'admin' => ADMIN_EVENTS, 'access' => ACCESS_EVENTS }
          .each do |category, names|
          names.each do |name|
            entry = EventCatalog.fetch(name)
            assert_equal category, entry.category, "#{name} should be a #{category} event"
          end
        end
      end

      test 'only access events have a runtime group, and every group is a known one' do
        EventCatalog.entries.each_value do |entry|
          if entry.category == 'access'
            assert_includes EventCatalog::RUNTIME_GROUPS, entry.runtime_group, "#{entry.name} needs a runtime group"
          else
            assert_nil entry.runtime_group, "#{entry.name} is not a runtime event"
          end
        end
      end

      test 'the denied group covers the two denial events' do
        assert_equal :denied, EventCatalog.fetch('access.denied').runtime_group
        assert_equal :denied, EventCatalog.fetch('action.denied').runtime_group
        assert_equal :bypass, EventCatalog.fetch('rule.bypassed').runtime_group
        assert_equal :bypass, EventCatalog.fetch('field.unmasked_without_user').runtime_group
        assert_equal :field_read, EventCatalog.fetch('field.access').runtime_group
        assert_equal :cache, EventCatalog.fetch('permissions.rebuilt').runtime_group
      end

      test 'an unknown event raises' do
        error = assert_raises(EventCatalog::UnknownEventError) { EventCatalog.fetch('permission_set.renamed') }
        assert_match(/permission_set\.renamed/, error.message)
        assert_kind_of ArgumentError, error
      end

      test 'registered? answers without raising' do
        assert EventCatalog.registered?('permission_set.created')
        assert_not EventCatalog.registered?('nope.nope')
        assert_not EventCatalog.registered?(nil)
      end

      test 'a host can register its own event with one call' do
        EventCatalog.register('host.something_happened', category: 'system')
        assert_equal 'system', EventCatalog.fetch('host.something_happened').category
      ensure
        EventCatalog.unregister('host.something_happened')
      end

      test 'registering rejects an unknown category or runtime group' do
        assert_raises(ArgumentError) { EventCatalog.register('host.bad', category: 'weird') }
        assert_raises(ArgumentError) { EventCatalog.register('host.bad', category: 'access', runtime_group: :nope) }
        assert_not EventCatalog.registered?('host.bad')
      end

      test 'names are strings and the registry is keyed by name' do
        assert_equal 'assignment.revoked', EventCatalog.fetch(:'assignment.revoked').name
        assert_includes EventCatalog.names, 'assignment.revoked'
      end
    end
  end
end
