require 'test_helper'
require_relative 'tenancy_test_helper'
require 'erb'
require 'generators/permission_forge/install/install_generator'

module PermissionForge
  module Tenancy
    # The configuration surface of multi-tenancy: how the tenant model maps to
    # the association and column, that HasTenantScoping honours both and is
    # safe to re-apply, that boot refuses a tenant_model without the gem, and
    # that the install generator writes a working multi-tenant setup.
    class TenantConfigurationTest < ActiveSupport::TestCase
      include TenancyTestHelper

      # Throwaway model: acts_as_tenant mutates the class it is applied to, so
      # the shared PermissionForge models must never be re-scoped from a test.
      class TenantColumnWidget < ActiveRecord::Base
        self.table_name = 'permission_sets'
        include PermissionForge::Concerns::HasTenantScoping
      end

      # --- configuration ------------------------------------------------------

      test 'tenant_enabled? follows tenant_model' do
        config.tenant_model = nil
        assert_not config.tenant_enabled?
        assert_nil config.tenant_association_name
        assert_nil config.resolved_tenant_column

        config.tenant_model = 'Account'
        assert config.tenant_enabled?
      end

      test 'association name and column are inferred from the model' do
        assert_equal :account, config.tenant_association_name
        assert_equal :account_id, config.resolved_tenant_column
      end

      test 'a namespaced tenant model yields a valid association name and column' do
        config.tenant_model = 'Billing::Account'

        assert_equal :account, config.tenant_association_name
        assert_equal :account_id, config.resolved_tenant_column
      end

      test 'tenant_column overrides the inferred column, as string or symbol' do
        config.tenant_column = 'org_id'
        assert_equal :org_id, config.resolved_tenant_column

        config.tenant_column = :organisation_id
        assert_equal :organisation_id, config.resolved_tenant_column
      end

      # --- HasTenantScoping ---------------------------------------------------

      test 'apply_tenant_scoping! declares acts_as_tenant on the configured column and is idempotent' do
        config.tenant_column = :org_id

        TenantColumnWidget.apply_tenant_scoping!
        TenantColumnWidget.apply_tenant_scoping!

        assert TenantColumnWidget.tenant_scoping_applied?
        reflection = TenantColumnWidget.reflect_on_association(:account)
        assert_equal 'org_id', reflection.foreign_key.to_s
        assert_equal 'Account', reflection.class_name
        assert_equal 1, TenantColumnWidget.default_scopes.size, 'a second application must not add a second scope'
        sql = within(Account.first) { TenantColumnWidget.all.to_sql }
        assert_match(/org_id/, sql)
      end

      test 'apply_tenant_scoping! is a no-op while multi-tenancy is off' do
        config.tenant_model = nil
        klass = Class.new(ActiveRecord::Base) do
          self.table_name = 'permission_sets'
          include PermissionForge::Concerns::HasTenantScoping
        end

        klass.apply_tenant_scoping!

        assert_not klass.tenant_scoping_applied?
      end

      test 'the shared permission models are tenant scoped exactly once' do
        PermissionForge::TestModels.all.each do |model|
          assert model.tenant_scoping_applied?, "#{model.name} should be tenant scoped"
          assert_equal 1, model.default_scopes.size, "#{model.name} should carry a single default scope"
        end
      end

      # --- boot ---------------------------------------------------------------

      test 'boot refuses a tenant_model when acts_as_tenant is not loaded' do
        hidden = Object.send(:remove_const, :ActsAsTenant)

        error = assert_raises(PermissionForge::ConfigurationError) do
          PermissionForge::BootChecks.ensure_tenancy_gem!(config)
        end
        assert_match(/acts_as_tenant gem is not loaded/, error.message)
        assert_match(/Account/, error.message)
      ensure
        Object.const_set(:ActsAsTenant, hidden) if hidden && !Object.const_defined?(:ActsAsTenant)
      end

      test 'boot skips tenant scoping entirely when tenant_model is nil' do
        config.tenant_model = nil
        hidden = Object.send(:remove_const, :ActsAsTenant)

        assert_nothing_raised { PermissionForge::BootChecks.ensure_tenancy_gem!(config) }
      ensure
        Object.const_set(:ActsAsTenant, hidden) if hidden && !Object.const_defined?(:ActsAsTenant)
      end

      test 'boot-time masking sees the models of every tenant' do
        tenant_a = Account.create!(name: 'A')
        tenant_b = Account.create!(name: 'B')
        within(tenant_a) { create_resource(permission_set: create_permission_set, name: 'Customer') }
        within(tenant_b) { create_resource(permission_set: create_permission_set, name: 'Supplier') }

        names = within(tenant_a) { PermissionForge::MaskedModels.send(:resource_names) }

        assert_includes names, 'Customer'
        assert_includes names, 'Supplier'
      end

      # --- install generator --------------------------------------------------

      test 'the install generator derives the tenant column from the tenant model, namespaced or not' do
        plain = PermissionForge::Generators::InstallGenerator.new([], ['--tenant=Account'])
        namespaced = PermissionForge::Generators::InstallGenerator.new([], ['--tenant=Billing::Account'])
        none = PermissionForge::Generators::InstallGenerator.new([], [])

        assert_equal 'account_id', plain.send(:tenant_column)
        assert_equal 'account_id', namespaced.send(:tenant_column)
        assert_equal 'Billing::Account', namespaced.send(:tenant_model)
        assert_nil none.send(:tenant_column)
        assert_nil none.send(:tenant_model)
      end

      test 'the install migration indexes the tenant column on every table' do
        with_tenant = render_template('migration.rb.tt', migration_version: '[7.1]', table_prefix: 'permission_forge_',
                                                         tenant_column: 'account_id')
        without = render_template('migration.rb.tt', migration_version: '[7.1]', table_prefix: 'permission_forge_',
                                                     tenant_column: nil)

        assert_equal 9, with_tenant.scan(/t\.bigint\s+:account_id/).size
        assert_equal 9, with_tenant.scan(/t\.index\s+:account_id/).size
        assert_no_match(/account_id/, without)
        assert RubyVM::InstructionSequence.compile(with_tenant)
      end

      test 'the install initializer enables multi-tenancy only when --tenant is given' do
        with_tenant = render_template('initializer.rb.tt', table_prefix: 'permission_forge_', tenant_model: 'Account')
        without = render_template('initializer.rb.tt', table_prefix: 'permission_forge_', tenant_model: nil)

        assert_match(/^\s*config\.tenant_model = 'Account'$/, with_tenant)
        assert_match(/^\s*# config\.tenant_model = 'Account'$/, without)
        assert_no_match(/^\s*config\.tenant_model = /, without)
        assert RubyVM::InstructionSequence.compile(with_tenant)
        assert RubyVM::InstructionSequence.compile(without)
      end

      private

      def config
        PermissionForge.configuration
      end

      def render_template(name, **locals)
        render_install_template(name, **locals)
      end
    end
  end
end
