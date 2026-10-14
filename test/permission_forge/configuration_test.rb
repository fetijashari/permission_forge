require 'test_helper'

module PermissionForge
  class ConfigurationTest < ActiveSupport::TestCase
    setup do
      @config = PermissionForge::Configuration.new
    end

    test 'has a default user_class' do
      assert_equal 'User', @config.user_class
    end

    test 'has a default cache_backend' do
      assert_equal :memory, @config.cache_backend
    end

    test 'has a default table_name_prefix' do
      assert_equal 'permission_forge_', @config.table_name_prefix
    end

    test 'has a default cache_key_prefix' do
      assert_equal 'pf', @config.cache_key_prefix
    end

    test 'has default ignored_fields' do
      assert_includes @config.ignored_fields, 'id'
      assert_includes @config.ignored_fields, 'created_at'
      assert_includes @config.ignored_fields, 'updated_at'
      assert_includes @config.ignored_fields, 'password'
    end

    test 'has default field_variant_mappings' do
      assert_equal 2, @config.field_variant_mappings.size
    end

    test 'has a default extra_fields_method' do
      assert_equal :extra_fields_for_permissions, @config.extra_fields_method
    end

    test 'virtual attribute options default to today\'s behaviour' do
      assert_equal :grant, @config.extra_fields_default_access
      assert_equal false, @config.virtual_field_discovery
      assert_equal false, @config.mask_virtual_attributes
      assert @config.grant_extra_fields_by_default?
      assert_not @config.mask_virtual_attributes_for?('Customer')
    end

    test 'only the exact :grant value grants extra fields by default' do
      @config.extra_fields_default_access = :unconfigured
      assert_not @config.grant_extra_fields_by_default?

      assert_raises(PermissionForge::ConfigurationError) { @config.extra_fields_default_access = :typo }
      assert_not @config.grant_extra_fields_by_default?

      @config.extra_fields_default_access = 'grant'
      assert @config.grant_extra_fields_by_default?
    end

    test 'mask_virtual_attributes_for? follows auto, list and off' do
      @config.mask_virtual_attributes = :auto
      assert @config.mask_virtual_attributes_for?('Customer')

      @config.mask_virtual_attributes = true
      assert @config.mask_virtual_attributes_for?(:Customer)

      @config.mask_virtual_attributes = %w[Customer]
      assert @config.mask_virtual_attributes_for?('Customer')
      assert_not @config.mask_virtual_attributes_for?('Supplier')

      @config.mask_virtual_attributes = nil
      assert_not @config.mask_virtual_attributes_for?('Customer')

      @config.mask_virtual_attributes = :typo
      assert_not @config.mask_virtual_attributes_for?('Customer')
    end

    test 'controller action options default to discovery off and allow' do
      assert_equal false, @config.controller_action_discovery
      assert_nil @config.controller_action_resolver
      assert_nil @config.action_guard_bypass
      assert_equal :allow, @config.unconfigured_action_strategy
      assert @config.allow_unconfigured_actions?
      assert @config.controller_excluded?('rails/health')
    end

    test 'unknown unconfigured_action_strategy values are refused when set' do
      @config.unconfigured_action_strategy = :block
      assert_not @config.allow_unconfigured_actions?

      [:typo, nil].each do |value|
        assert_raises(PermissionForge::ConfigurationError) { @config.unconfigured_action_strategy = value }
      end
      assert_not @config.allow_unconfigured_actions?, 'the previous value stays'
    end

    test 'the default exclusion list is not shared between configurations' do
      @config.controller_discovery_exclude << 'api/'

      assert_not PermissionForge::Configuration.new.controller_excluded?('api/customers')
    end

    test 'has audit_trail_enabled by default' do
      assert @config.audit_trail_enabled
    end

    test 'has http_basic_auth_enabled true by default' do
      assert @config.http_basic_auth_enabled
    end

    test 'has base_controller_class default' do
      assert_equal '::ActionController::Base', @config.base_controller_class
    end

    test '#user_model constantizes the user_class' do
      assert_equal User, @config.user_model
    end

    test '#cache_store builds a MemoryCache for :memory backend' do
      @config.cache_backend = :memory
      @config.reset_cache_store!
      assert_kind_of PermissionForge::Cache::MemoryCache, @config.cache_store
    end

    test '#cache_store builds a NullCache for :null backend' do
      @config.cache_backend = :null
      @config.reset_cache_store!
      assert_kind_of PermissionForge::Cache::NullCache, @config.cache_store
    end

    test '#cache_store builds a RailsCache for :rails_cache backend' do
      @config.cache_backend = :rails_cache
      @config.reset_cache_store!
      assert_kind_of PermissionForge::Cache::RailsCache, @config.cache_store
    end

    test '#cache_store wraps an ActiveSupport::Cache::Store instance in RailsCache' do
      @config.cache_backend = ActiveSupport::Cache::MemoryStore.new
      @config.reset_cache_store!
      assert_kind_of PermissionForge::Cache::RailsCache, @config.cache_store
    end

    test '#cache_store raises for unknown backend' do
      @config.cache_backend = :unknown
      @config.reset_cache_store!
      error = assert_raises(ArgumentError) { @config.cache_store }
      assert_match(/Unknown cache backend/, error.message)
    end

    test 'field_variant_mappings maps _id fields to _uuid' do
      mapping = @config.field_variant_mappings.find { |k, _| 'supplier_id'.match?(k) }
      assert_equal 'supplier_uuid', mapping.last.call('supplier_id')
    end

    test 'field_variant_mappings maps _cents fields to base name' do
      mapping = @config.field_variant_mappings.find { |k, _| 'price_cents'.match?(k) }
      assert_equal 'price', mapping.last.call('price_cents')
    end

    test '#audit_user_model constantizes the audit_user_class' do
      assert_equal User, @config.audit_user_model
    end

    test '#user_list defaults to user_model ordered by id' do
      sql = @config.user_list.to_sql
      assert_match(/FROM ["`]users["`]/i, sql)
      assert_match(/ORDER BY ["`]?users["`]?\.["`]?id["`]?/i, sql)
    end

    test '#user_list uses user_list_resolver when configured' do
      sentinel = Object.new
      @config.user_list_resolver = -> { sentinel }
      assert_same sentinel, @config.user_list
    end

    test '#assignable_users excludes given ids on AR relations' do
      u1 = User.create!(name: 'A')
      u2 = User.create!(name: 'B')
      ids = @config.assignable_users(exclude_ids: [u1.id]).pluck(:id)
      refute_includes ids, u1.id
      assert_includes ids, u2.id
    end

    test '#assignable_users handles array-based resolvers' do
      stub_user = Struct.new(:id)
      u1 = stub_user.new(1)
      u2 = stub_user.new(2)
      @config.user_list_resolver = -> { [u1, u2] }
      result = @config.assignable_users(exclude_ids: [1])
      assert_equal [u2], result
    end

    test 'has a default user_list_limit of 500' do
      assert_equal 500, @config.user_list_limit
    end

    test '#assignable_users caps AR relations at user_list_limit' do
      3.times { |i| User.create!(name: "Capped #{i}") }
      @config.user_list_limit = 2

      assert_equal 2, @config.assignable_users.length
    end

    test '#assignable_users applies the cap after exclusions' do
      users = 3.times.map { |i| User.create!(name: "Excluded #{i}") }
      @config.user_list_limit = 2

      ids = @config.assignable_users(exclude_ids: [users.first.id]).pluck(:id)

      refute_includes ids, users.first.id
      assert_equal 2, ids.length
    end

    test '#assignable_users caps array-based resolvers' do
      stub_user = Struct.new(:id)
      @config.user_list_resolver = -> { (1..5).map { |i| stub_user.new(i) } }
      @config.user_list_limit = 3

      result = @config.assignable_users

      assert_equal [1, 2, 3], result.map(&:id)
    end

    test '#assignable_users preserves a smaller limit set by the resolver' do
      2.times { |i| User.create!(name: "Resolver Limited #{i}") }
      @config.user_list_resolver = -> { User.order(:id).limit(1) }
      @config.user_list_limit = 500

      assert_equal 1, @config.assignable_users.length
    end

    test '#assignable_users applies no cap when user_list_limit is nil' do
      @config.user_list_limit = nil
      stub_user = Struct.new(:id)
      @config.user_list_resolver = -> { (1..600).map { |i| stub_user.new(i) } }

      assert_equal 600, @config.assignable_users.length
    end

    test 'PermissionForge.reset! creates a fresh configuration' do
      PermissionForge.configuration.cache_key_prefix = 'custom'
      PermissionForge.reset!
      assert_equal 'pf', PermissionForge.configuration.cache_key_prefix
    end

    # --- GDPR configuration ---

    test 'gdpr_defaults is true by default' do
      assert @config.gdpr_defaults
    end

    test 'gdpr_field_patterns has default patterns' do
      patterns = @config.gdpr_field_patterns
      assert(patterns.any? { |regex, _| 'email'.match?(regex) })
      assert(patterns.any? { |regex, _| 'phone'.match?(regex) })
      assert(patterns.any? { |regex, _| 'first_name'.match?(regex) })
      assert(patterns.any? { |regex, _| 'address'.match?(regex) })
    end

    test 'gdpr_field_patterns can be overridden' do
      @config.gdpr_field_patterns = { /custom/ => 'full' }
      assert_equal 1, @config.gdpr_field_patterns.size
    end

    test 'DEFAULT_GDPR_FIELD_PATTERNS matches email variants' do
      patterns = PermissionForge::Configuration::DEFAULT_GDPR_FIELD_PATTERNS
      assert(patterns.any? { |regex, strategy| 'email'.match?(regex) && strategy == 'email' })
      assert(patterns.any? { |regex, strategy| 'work_email'.match?(regex) && strategy == 'email' })
    end

    test 'DEFAULT_GDPR_FIELD_PATTERNS matches phone variants' do
      patterns = PermissionForge::Configuration::DEFAULT_GDPR_FIELD_PATTERNS
      assert(patterns.any? { |regex, strategy| 'phone'.match?(regex) && strategy == 'last4' })
      assert(patterns.any? { |regex, strategy| 'mobile_phone'.match?(regex) && strategy == 'last4' })
    end
  end
end
