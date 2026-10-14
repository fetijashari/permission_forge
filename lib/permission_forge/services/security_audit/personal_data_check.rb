# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Personal data shown unmasked, from GdprFieldAuditor. Fields an admin
      # marked "This is intended" in the privacy audit are left out.
      class PersonalDataCheck < BaseCheck
        def call
          report = GdprFieldAuditor.call(configuration: configuration)
          [unmasked(report), implicit_virtual(report), cross_set(report), unmapped(report)].compact
        end

        private

        def unmasked(report)
          rows = report.select { |row| row[:type] == :unmasked_field && acknowledged_ids.exclude?(row[:resource_field_id]) }
          return if rows.empty?

          finding(:medium, :unmasked_personal_data, 'Personal data readable unmasked',
                  'These fields look like personal data and are readable without a mask. Mask them, or mark ' \
                  'them "This is intended" in the admin privacy audit if that access is deliberate.',
                  items: rows.map do |row|
                    "#{row[:permission_set]} › #{row[:resource_name]}.#{row[:field_name]} (suggested: #{row[:suggested_strategy]})"
                  end)
        end

        # Declared virtual fields left on the implicit grant: readable and
        # editable, unmasked, without anyone having chosen that. A field whose
        # only row is switched off is one of them.
        def implicit_virtual(report)
          rows = report.select { |row| row[:type] == :implicit_virtual_grant }
          return if rows.empty?

          finding(:medium, :implicit_virtual_personal_data, 'Personal data in virtual fields granted by default',
                  'These virtual fields look like personal data and have no active field row, so ' \
                  'extra_fields_default_access = :grant makes them readable and editable, unmasked. Give them a ' \
                  'level, or set extra_fields_default_access = :unconfigured so they follow unconfigured_field_strategy.',
                  items: rows.map do |row|
                    "#{row[:permission_set]} › #{row[:resource_name]}.#{row[:field_name]} (suggested: #{row[:suggested_strategy]})"
                  end)
        end

        def cross_set(report)
          rows = report.select { |row| row[:type] == :cross_set_unmasking }
          return if rows.empty?

          finding(:medium, :cross_set_unmasking, 'One set unmasks what another masks',
                  'Masks combine with AND: anyone holding both sets sees the full value.',
                  items: rows.map { |row| "#{row[:permission_set]} › #{row[:resource_name]}.#{row[:field_name]}" })
        end

        def unmapped(report)
          rows = report.select { |row| row[:type] == :unmapped_column }
          return if rows.empty?

          passes = %w[pass_through warn].include?(configuration.unconfigured_field_strategy.to_s)
          detail = if passes
                     'unconfigured_field_strategy lets them through unfiltered. Add a field row, or switch ' \
                       'the existing one back on.'
                   else
                     'They are blocked from filtered responses until configured; add a field row (or switch ' \
                       'the existing one back on) to decide.'
                   end
          finding(passes ? :high : :low, :unmapped_personal_data, 'Personal-data columns with no active field row', detail,
                  items: rows.map { |row| "#{row[:resource]}.#{row[:column]}" })
        end

        def acknowledged_ids
          @acknowledged_ids ||= if PermissionForge::Admin::AttentionItems.acknowledgement_supported?
                                  PermissionForge::ResourceField.where.not(sensitive_acknowledged_at: nil).pluck(:id).to_set
                                else
                                  Set.new
                                end
        end
      end
    end
  end
end
