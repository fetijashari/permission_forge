require 'test_helper'

module PermissionForge
  module Audit
    class SettingsObserverTest < ActiveSupport::TestCase
      def observed = PermissionForge::AuditEvent.where(event: 'audit.settings_observed').order(:id)

      test 'records the settings the first time' do
        assert_difference -> { observed.count }, 1 do
          event = SettingsObserver.call

          assert_equal 'system', event.actor_type
          assert_equal 'auto', event.data['settings']['audit_events']
          assert_equal 'unset', event.data['settings']['audit_actor_resolver']
        end
      end

      test 'does not record again when nothing changed' do
        SettingsObserver.call

        assert_no_difference -> { observed.count } do
          assert_nil SettingsObserver.call
        end
      end

      test 'records again when a setting changed, and when it changes back' do
        SettingsObserver.call
        PermissionForge.configuration.audit_runtime_events = %i[denied field_read]

        assert_difference -> { observed.count }, 1 do
          assert_equal %w[denied field_read], SettingsObserver.call.data['settings']['audit_runtime_events']
        end
        PermissionForge.configuration.audit_runtime_events = %i[denied]

        assert_difference -> { observed.count }, 1 do
          SettingsObserver.call
        end
      end

      test 'lambdas are recorded as set or unset, never their code' do
        PermissionForge.configuration.audit_actor_resolver = ->(_controller) { 'secret-body' }
        event = SettingsObserver.call

        assert_equal 'set', event.data['settings']['audit_actor_resolver']
        assert_no_match(/secret-body/, event.data.to_json)
      end

      test 'durations are recorded in seconds' do
        PermissionForge.configuration.audit_retention_period = 90.days

        assert_equal 90.days.to_i, SettingsObserver.call.data['settings']['audit_retention_period']
      end

      test 'a boot with auditing off still records that it was off; off then on records two events' do
        PermissionForge.configuration.audit_events = false

        assert_difference -> { observed.count }, 1 do
          assert_equal false, SettingsObserver.call.data['settings']['audit_events']
          assert_nil SettingsObserver.call
        end
        PermissionForge.configuration.audit_events = :auto

        assert_difference -> { observed.count }, 1 do
          assert_equal 'auto', SettingsObserver.call.data['settings']['audit_events']
        end
        assert_equal [false, 'auto'], observed.map { |e| e.data['settings']['audit_events'] }.last(2)
      end

      test 'records nothing and does not raise when the table is missing' do
        PermissionForge::AuditEvent.define_singleton_method(:table_exists?) { false }

        assert_nil SettingsObserver.call
      ensure
        singleton = PermissionForge::AuditEvent.singleton_class
        singleton.send(:remove_method, :table_exists?) if singleton.method_defined?(:table_exists?, false)
      end

      test 'a failure while recording is swallowed' do
        original = PermissionForge::Audit.method(:record)
        replace_singleton_method(PermissionForge::Audit, :record) { |*, **| raise 'boom' }

        assert_nil SettingsObserver.call
      ensure
        replace_singleton_method(PermissionForge::Audit, :record, original)
      end
    end
  end
end
