# frozen_string_literal: true

ENV['SKIP_COVERAGE'] = '1'
ENV['RAILS_ENV'] = 'test'

require_relative '../dummy/config/environment'
require 'benchmark'

# Load schema
ActiveRecord::Schema.verbose = false
load File.expand_path('../dummy/db/schema.rb', __dir__)

# Configure PermissionForge for benchmarks
PermissionForge.configure do |config|
  config.user_class = 'User'
  config.current_user_resolver = -> { Current.user }
  config.user_active_check = lambda(&:active_for_authentication?)
  config.cache_backend = :memory
  config.table_name_prefix = ''
  config.audit_trail_enabled = false
  config.http_basic_auth_enabled = false
end

module BenchmarkHelpers
  FIELD_TEMPLATES = {
    name: 'Customer Name',
    email: 'user@example.com',
    phone: '+1-555-123-4567',
    domain: 'example.com',
    address: '123 Main Street, Suite 100',
    city: 'New York',
    state: 'NY',
    zip_code: '10001',
    country: 'United States',
    tax_id: 'US123456789',
    website: 'https://www.example.com',
    notes: 'Important customer with long-term contract and special pricing arrangements.',
    status: 'active',
    category: 'enterprise',
    reference_number: 'REF-2024-00001'
  }.freeze

  EXTRA_FIELDS = {
    department: 'Engineering',
    title: 'Senior Manager',
    company: 'Acme Corp',
    industry: 'Technology',
    revenue: '1000000',
    employee_count: '500',
    region: 'North America',
    segment: 'mid-market',
    source: 'referral',
    priority: 'high',
    tier: 'gold',
    currency: 'USD',
    language: 'en',
    timezone: 'America/New_York',
    account_manager: 'Jane Doe',
    last_contacted: '2024-01-15',
    contract_start: '2024-01-01',
    contract_end: '2025-12-31',
    payment_terms: 'net30',
    credit_limit: '50000',
    discount_rate: '0.15',
    shipping_address: '456 Oak Avenue, Building B',
    billing_address: '789 Pine Road, Floor 3',
    contact_name: 'John Smith',
    contact_email: 'john@example.com',
    contact_phone: '+1-555-987-6543',
    fax: '+1-555-111-2222',
    vat_number: 'DE123456789',
    duns_number: '12-345-6789',
    sic_code: '7372',
    naics_code: '511210',
    founded_year: '1995',
    description: 'A leading provider of enterprise software solutions.',
    tags: 'enterprise,software,saas',
    custom_field_1: 'Custom value for field 1'
  }.freeze

  # Generate N attribute hashes with the given field count
  def generate_attributes(count, field_count: 15)
    all_fields = FIELD_TEMPLATES.merge(EXTRA_FIELDS)
    selected = all_fields.first(field_count).to_h

    count.times.map do |i|
      selected.transform_values { |v| "#{v}_#{i}" }
    end
  end

  # Build field names for a given count
  def field_names_for(field_count)
    all_fields = FIELD_TEMPLATES.merge(EXTRA_FIELDS)
    all_fields.keys.first(field_count)
  end

  # Create a user with permission set, resource, and configured fields
  # fields_config is an array of hashes: { name:, read_access:, edit_access:, mask_access:, mask_strategy: }
  def setup_user_with_permissions(resource_name:, fields_config:)
    PermissionForge.cache.clear

    user = User.create!(
      uuid: SecureRandom.uuid,
      name: 'Benchmark User',
      email: "bench_#{SecureRandom.hex(4)}@example.com",
      deactivated: false
    )

    permission_set = PermissionForge::PermissionSet.create!(
      uuid: SecureRandom.uuid,
      name: 'Benchmark Set',
      is_active: true,
      is_editable: true
    )

    PermissionForge::PermissionSetUser.create!(
      uuid: SecureRandom.uuid,
      user: user,
      permission_set: permission_set
    )

    resource = PermissionForge::Resource.create!(
      uuid: SecureRandom.uuid,
      name: resource_name,
      permission_set: permission_set,
      is_active: true,
      is_editable: true,
      read_access: true,
      create_access: true,
      edit_access: true,
      delete_access: true
    )

    fields_config.each do |fc|
      PermissionForge::ResourceField.create!(
        uuid: SecureRandom.uuid,
        name: fc[:name].to_s,
        label: fc[:name].to_s.titleize,
        resource: resource,
        is_active: true,
        is_editable: true,
        read_access: fc.fetch(:read_access, true),
        edit_access: fc.fetch(:edit_access, true),
        mask_access: fc.fetch(:mask_access, false),
        mask_strategy: fc.fetch(:mask_strategy, 'full')
      )
    end

    user.regenerate_permissions
    Current.user = user

    [user, resource, permission_set]
  end

  # Build a standard mixed fields config for a given field count
  # ~60% readable, ~20% masked, ~20% hidden
  def mixed_fields_config(field_count)
    names = field_names_for(field_count)
    mask_strategies = %w[email last4 first1_last4 full]

    readable_count = (field_count * 0.6).ceil
    masked_count = (field_count * 0.2).ceil
    hidden_count = field_count - readable_count - masked_count

    # Readable fields (no mask)
    config = names[0, readable_count].map do |name|
      { name: name, read_access: true, edit_access: true, mask_access: false }
    end

    # Masked fields
    names[readable_count, masked_count].each_with_index do |name, i|
      config << { name: name, read_access: true, edit_access: false, mask_access: true,
                  mask_strategy: mask_strategies[i % mask_strategies.size] }
    end

    # Hidden fields
    names[readable_count + masked_count, hidden_count].each do |name|
      config << { name: name, read_access: false, edit_access: false, mask_access: false }
    end

    config
  end

  # Run a block with GC disabled for more stable timing
  def measure_without_gc(label = nil, &)
    GC.start
    GC.disable
    result = Benchmark.measure(label || '', &)
    GC.enable
    result
  end

  # Print a formatted comparison report
  def print_report(title, scenarios)
    puts "\n#{'=' * 70}"
    puts "  #{title}"
    puts '=' * 70

    baseline = scenarios.find { |s| s[:label] =~ /baseline/i }

    fmt = '  %-35s %10s %12s %12s'
    puts format(fmt, 'Scenario', 'Total (s)', 'Per-record', 'Overhead')
    puts "  #{'-' * 69}"

    scenarios.each do |s|
      total = s[:time]
      count = s[:count]
      per_record = total / count
      overhead = baseline ? total - baseline[:time] : 0.0

      puts format(fmt,
                  s[:label],
                  format('%.4f', total),
                  format('%.4fms', per_record * 1000),
                  baseline && s != baseline ? format('+%.4fms', (overhead / count) * 1000) : '-')
    end

    puts
  end
end
