# frozen_string_literal: true

require 'test_helper'
require_relative '../field_variant_models'

module PermissionForge
  module Services
    # Field test (round 4, d #59): a field named after nothing on the model
    # (`zzz`) was saved — 201 through the API — and configured nothing, so a
    # typo went unnoticed. Saving still accepts it (FiltersResponseAttributes
    # filters any hash key, so a key only a serializer computes is configured
    # by a row of its name); `rake permission_forge:audit` reports it.
    class SecurityAuditUnknownFieldsTest < ActiveSupport::TestCase
      # A store, an accessor with a custom prefix and an attribute-API
      # attribute over the customers table. It never gets a Resource row
      # (that would mix MaskedAttributes into it): FieldNames is asked directly.
      class PfFieldNameStore < ApplicationRecord
        self.table_name = 'customers'

        store :domain, accessors: [:theme], coder: JSON
        store_accessor :domain, :color, prefix: :ui
        attribute :nickname, :string
      end

      # A single-table-inheritance subclass of Customer with a method of its own.
      class PfFieldNameVipCustomer < Customer
        def vip_level = 1
      end

      setup do
        @config = PermissionForge::Configuration.new
        @config.user_class = 'User'
        @set = create_permission_set(name: 'Sales')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
      end

      def audit
        SecurityAudit.call(configuration: @config, environment: 'test')
      end

      def finding(report) = report.findings.find { |f| f.code == :unknown_fields }

      test 'a row naming nothing on its model still saves, and the audit lists it (info for a granting set)' do
        create_user.tap { |user| create_permission_set_user(user: user, permission_set: @set) }
        typo = create_resource_field(resource: @resource, name: 'emial')
        create_resource_field(resource: @resource, name: 'email')

        assert typo.persisted?
        found = finding(audit)

        assert_equal :info, found.severity
        assert_equal 'integrity', found.check
        assert_equal ['Sales › Customer.emial · 1 person'], found.items
      end

      test 'a muting set holding one makes it low: it mutes nothing' do
        muting = create_permission_set(name: 'Mute email', is_muting: true)
        resource = create_resource(permission_set: muting, name: 'Customer', read_access: false)
        create_resource_field(resource: resource, name: 'emial', read_access: true, edit_access: false)

        found = finding(audit)

        assert_equal :low, found.severity
        assert_equal ['Mute email (muting) › Customer.emial · 0 people'], found.items
      end

      test 'columns, declared virtual fields, readers and variants are not listed' do
        # a column, the primary key, declared virtual fields, an association
        # reader, a variant of supplier_id the model does not have (a serializer key)
        %w[email id created_at full_address contact_count supplier supplier_uuid].each do |name|
          create_resource_field(resource: @resource, name: name, label: name)
        end

        assert_nil finding(audit)
      end

      # Review round 5: a row on the base Resource reaches the subclass's
      # records (ResourceChain), so a name only the subclass has is a field.
      test 'a name a loaded STI subclass on the same table has is a field of the base Resource' do
        create_resource_field(resource: @resource, name: 'vip_level')
        create_resource_field(resource: @resource, name: 'vip_levle')

        assert_equal ['Sales › Customer.vip_levle · 0 people'], finding(audit).items
        assert FieldNames.for('Customer').include?('vip_level')
        assert_not FieldNames.for('User').include?('vip_level'), 'another model is not a subclass'
      end

      test 'rows that are not in effect, and Resources whose model cannot be loaded, are not listed' do
        create_resource_field(resource: @resource, name: 'zzz', is_active: false)
        other = create_resource(permission_set: create_permission_set(name: 'Other'), name: 'FreightCost')
        create_resource_field(resource: other, name: 'zzz')

        assert_nil finding(audit)
      end

      test 'FieldNames: aliases, readers, writers, stores, attributes and variants are fields' do
        orders = PermissionForge::FieldNames.for('PfVariantOrder')
        %w[account_uuid price team_uuid region_uuid owner_uuid title].each { |name| assert orders.include?(name), name }
        assert_not orders.include?('titel')

        stores = PermissionForge::FieldNames.for(PfFieldNameStore.name)
        %w[theme ui_color nickname domain].each { |name| assert stores.include?(name), name }
        assert_not stores.include?('colour')
      end

      test 'FieldNames: a configured variant of a column or of another row of the Resource is a field' do
        @config.field_variant_mappings = { /_code\z/ => ->(name) { name.sub(/_code\z/, '_label') },
                                           /\Atitle\z/ => ->(_name) { 'heading' } }
        names = PermissionForge::FieldNames.for('PfVariantOrder', configuration: @config)

        assert names.include?('heading'), 'a variant of the title column'
        assert_not names.include?('region_label')
        assert PermissionForge::FieldNames.for('PfVariantOrder', siblings: -> { %w[region_code] }, configuration: @config)
                                          .include?('region_label'), 'a variant of another row'
      end

      test 'FieldNames: a column added after the schema cache was read is a field' do
        Customer.columns_hash # warm the cache
        ActiveRecord::Base.connection.add_column(:customers, :pf_region, :string)

        assert PermissionForge::FieldNames.for('Customer').include?('pf_region')
      ensure
        ActiveRecord::Base.connection.remove_column(:customers, :pf_region) if Customer.connection.column_exists?(:customers, :pf_region)
        Customer.reset_column_information
      end

      test 'FieldNames: nothing is said when the model cannot be told' do
        %w[NoSuchModelAnywhere Comparable].each { |name| assert_nil PermissionForge::FieldNames.for(name), name }
        assert_nil PermissionForge::FieldNames.for(nil)
      end
    end
  end
end
