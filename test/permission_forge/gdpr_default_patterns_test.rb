# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # The default GDPR field patterns serve two readers with one definition:
  # masking detection (ResourceFieldGenerator, GdprFieldAuditor,
  # Admin::SensitiveColumns, the security audit) and, through
  # PermissionForge.gdpr_filter_parameters, Rails' config.filter_parameters —
  # which Rails also copies into ActiveRecord::Base.filter_attributes, so a
  # matching attribute prints as [FILTERED] in #inspect and the logs. A
  # pattern matches the way Rails' own filter_parameter_logging does (a
  # substring: `phone` in `cellphone`), except that a stem short enough to be
  # part of an unrelated word (tel, city, zip, dob, fax, mobile) is matched as
  # a whole name segment — `telephone` yes, `hotel_id` no.
  class GdprDefaultPatternsTest < ActiveSupport::TestCase
    PERSONAL = %w[
      email contact_email work_email
      phone phone_number cellphone telephone telefon home_phone mobile mobile_phone mobilephone fax fax_number faxnumber
      tel tel_home home_tel tel2 home_tel2 telNumber
      ssn social_security_number national_id
      iban bank_account credit_card_number card_number
      name first_name last_name full_name contact_name
      address street_address email_address street city home_city cityName city2 zip zip_code zipcode zipCode postal_code
      date_of_birth dob dob_date dobDate birthday
      ip_address ip
      ethnicity ethnic_group telegram_id telegram_handle
    ].freeze

    NOT_PERSONAL = %w[
      capacity velocity electricity_meter hotel_id telemetry_enabled automobile_id gzip_enabled unzip_on_upload adobe_id
      title status company_name username nickname description quantity type
    ].freeze

    setup do
      PermissionForge.configuration.gdpr_defaults = true
    end

    test 'the filter parameters are the field patterns: one definition' do
      assert_equal PermissionForge.configuration.gdpr_field_patterns.keys, PermissionForge.gdpr_filter_parameters
      assert_equal Configuration::DEFAULT_GDPR_FIELD_PATTERNS.keys, PermissionForge.gdpr_filter_parameters
    end

    test 'every personal-data column name is detected and filtered' do
      filtered = filtered_names(PERSONAL)

      assert_equal PERSONAL.sort, filtered.sort
      assert_empty PERSONAL.reject { |name| detected?(name) }, 'detected for masking'
    end

    test 'a name that merely contains a stem is neither filtered nor detected' do
      assert_empty filtered_names(NOT_PERSONAL)
      assert_empty NOT_PERSONAL.select { |name| detected?(name) }, 'not treated as personal data'
    end

    # Rails 8's authentication generator names the column email_address. It
    # also matches `address`; the email pattern comes first and decides.
    test 'email_address is detected as an email, everywhere the patterns are read' do
      %w[email_address billing_email_address].each do |name|
        match = Admin::SensitiveColumns.new.match(name)
        assert_equal %w[email email_address], [match&.strategy, match&.pattern], name
      end
      assert_equal 'email', PermissionForge.configuration.gdpr_field_patterns.find { |pattern, _| 'email_address'.match?(pattern) }&.last
      assert_equal 'j***@example.com', Services::MaskValue.call('jane@example.com', strategy: 'email')
      assert_equal 'full', Admin::SensitiveColumns.new.match('street_address')&.strategy
      assert_equal 'full', Admin::SensitiveColumns.new.match('email_address_verified_at')&.strategy, 'an address column, not an email'
    end

    test 'Admin::SensitiveColumns still names the alternative that matched' do
      assert_equal 'last4', Admin::SensitiveColumns.new.match('telephone')&.strategy
      assert_equal 'full', Admin::SensitiveColumns.new.match('home_city')&.strategy
      assert_equal(%w[tel city dob], %w[telNumber cityName dob2].map { |name| Admin::SensitiveColumns.new.match(name)&.pattern })
      assert_nil Admin::SensitiveColumns.new.match('hotel_id')
    end

    private

    # What Rails filters: ActiveSupport::ParameterFilter is what both
    # config.filter_parameters and ActiveRecord::Base.filter_attributes use.
    def filtered_names(names)
      filter = ActiveSupport::ParameterFilter.new(PermissionForge.gdpr_filter_parameters)
      filter.filter(names.to_h { |name| [name, 'value'] }).select { |_, value| value == '[FILTERED]' }.keys
    end

    def detected?(name)
      PermissionForge.configuration.gdpr_field_patterns.any? { |pattern, _| name.match?(pattern) }
    end
  end
end
