require 'test_helper'

module PermissionForge
  module Audit
    # The audit boot warnings written by Engine.warn_audit_setup.
    class BootWarningsTest < ActiveSupport::TestCase
      setup do
        @log = StringIO.new
        @logger = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(@log)
        PermissionForge.configuration.http_basic_auth_enabled = false
        PermissionForge::Audit.reset!
      end

      teardown do
        Rails.logger = @logger
        PermissionForge.configuration.http_basic_auth_enabled = true
        PermissionForge::Audit.reset!
      end

      # The suite loads Rails::Generators (generator tests): a boot outside a generator is asked for.
      def warn_setup = PermissionForge::Audit::BootWarnings.call(PermissionForge.configuration, generating: false)

      test 'a missing table is warned about exactly once' do
        PermissionForge::AuditEvent.define_singleton_method(:table_exists?) { false }
        warn_setup
        warn_setup

        assert_equal 1, @log.string.scan('audit_events is :auto but the table').size
      ensure
        PermissionForge::AuditEvent.singleton_class.send(:remove_method, :table_exists?)
      end

      # PKG-N10: a fresh install booted before db:migrate was told to run the
      # upgrade generator, which would duplicate its migrations.
      test 'PKG-N10 a pending migration of the gem is a db:migrate, none is the upgrade generator' do
        Dir.mktmpdir do |dir|
          paths = ActiveRecord::Migrator.migrations_paths
          ActiveRecord::Migrator.migrations_paths = [dir]
          File.write(File.join(dir, '20261013000000_create_unrelated_audit_events.rb'), 'create_table :audit_events')
          assert_match(%r{generate permission_forge:upgrade, then bin/rails db:migrate}, BootWarnings.missing_table('pf_audit_events'))

          File.write(File.join(dir, '20261013000001_create_permission_forge_tables.rb'), 'create_table :pf_audit_events')
          message = BootWarnings.missing_table('pf_audit_events')
          assert_match(%r{until the pending migration has run \(bin/rails db:migrate\)}, message)
          assert_no_match(/permission_forge:upgrade/, message)
        ensure
          ActiveRecord::Migrator.migrations_paths = paths
        end
      end

      test 'PKG-N10 the logged missing-table warning carries the remedy' do
        PermissionForge::AuditEvent.define_singleton_method(:table_exists?) { false }
        warn_setup

        assert_includes @log.string, BootWarnings.missing_table(PermissionForge::AuditEvent.table_name)
      ensure
        PermissionForge::AuditEvent.singleton_class.send(:remove_method, :table_exists?)
      end

      # a-onboarding #64: `bin/rails generate permission_forge:install` boots the app before it writes
      # the migration; the boot told a fresh install to run the upgrade generator.
      test 'no missing-table warning while a generator runs; the first event checks again' do
        PermissionForge::AuditEvent.define_singleton_method(:table_exists?) { false }
        PermissionForge::Audit::BootWarnings.call(PermissionForge.configuration, generating: true)

        assert_no_match(/was not found/, @log.string)

        assert_not PermissionForge::Audit.enabled?
        assert_equal 1, @log.string.scan('audit_events is :auto but the table').size
      ensure
        PermissionForge::AuditEvent.singleton_class.send(:remove_method, :table_exists?)
      end

      test 'a generator is running once Rails::Generators is loaded' do
        require 'rails/generators'

        assert_predicate BootWarnings, :generator_running?
      end

      test 'no table warning when the table exists' do
        warn_setup

        assert_no_match(/was not found/, @log.string)
      end

      test 'audit switched off is warned about' do
        PermissionForge.configuration.audit_events = false
        warn_setup

        assert_match(/audit_events is false/, @log.string)
      end

      test 'no off warning while auditing is on' do
        warn_setup

        assert_no_match(/audit_events is false/, @log.string)
      end

      test 'shared basic auth without an actor resolver is warned about' do
        PermissionForge.configuration.http_basic_auth_enabled = true
        warn_setup

        assert_match(/attributed to the shared login/, @log.string)
      end

      test 'no shared login warning with a resolver or without basic auth' do
        PermissionForge.configuration.http_basic_auth_enabled = true
        PermissionForge.configuration.audit_actor_resolver = ->(_c) {}
        warn_setup
        PermissionForge.configuration.audit_actor_resolver = nil
        PermissionForge.configuration.http_basic_auth_enabled = false
        warn_setup

        assert_no_match(/shared login/, @log.string)
      end
    end
  end
end
