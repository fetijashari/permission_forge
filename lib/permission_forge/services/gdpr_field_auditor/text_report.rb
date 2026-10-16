# frozen_string_literal: true

module PermissionForge
  module Services
    class GdprFieldAuditor
      # Plain-text rendering of a GdprFieldAuditor report for terminals and
      # logs. One line per finding, whatever its type, so the count in the
      # header is the number of lines below it. An unmasked field names its
      # Permission Set after the "[UNMASKED] Resource.field" a CI script may
      # look for: the same field unmasked in three sets is three findings. The
      # strategy a finding carries (suggested_strategy, and pattern_matched of
      # an unmapped column) is the mask the matching pattern recommends, so the
      # line calls it the suggested strategy.
      #
      # @api private
      class TextReport
        CLEAN = 'All GDPR-sensitive fields are properly masked.'

        LINES = {
          unmasked_field: lambda { |finding|
            "[UNMASKED] #{finding[:resource_name]}.#{finding[:field_name]} (Permission Set: #{finding[:permission_set]}) " \
              "— personal data, not masked (suggested strategy: '#{finding[:suggested_strategy]}'#{TextReport.matched(finding)})"
          },
          unmapped_column: lambda { |finding|
            "[UNMAPPED] #{finding[:resource]}.#{finding[:column]} " \
              "— personal data, no active ResourceField (suggested strategy: '#{finding[:pattern_matched]}'#{TextReport.matched(finding)})"
          },
          implicit_virtual_grant: lambda { |finding|
            "[VIRTUAL] #{finding[:permission_set]} › #{finding[:resource_name]}.#{finding[:field_name]} " \
              "— matches a GDPR pattern (suggested mask: '#{finding[:suggested_strategy]}'), " \
              'no active ResourceField, readable and editable by default'
          },
          view_all_on_pii_resource: lambda { |finding|
            "[VIEW ALL] #{finding[:permission_set]} › #{finding[:resource_name]} " \
              "— #{finding[:bypasses].join(' + ')} skips row-level rules; GDPR-sensitive fields " \
              "on this resource: #{finding[:pii_fields].join(', ')}"
          },
          cross_set_unmasking: lambda { |finding|
            "[OVERRIDES MASK] #{finding[:permission_set]} › #{finding[:resource_name]}.#{finding[:field_name]} " \
              "— unmasked here, masked in #{TextReport.masking_sets(finding)}; a person in both sees the full value"
          }
        }.freeze

        # A finding type added to the auditor without a line here still prints.
        FALLBACK = lambda { |finding|
          "[#{finding[:type].to_s.upcase.tr('_', ' ')}] " \
            "#{finding.except(:type).map { |key, value| "#{key}: #{value}" }.join(', ')}"
        }

        # The Permission Sets a cross-set finding says mask the field (a
        # finding without them says "another Permission Set").
        #
        # @return [String]
        def self.masking_sets(finding)
          names = Array(finding[:masked_in])
          return 'another Permission Set' if names.empty?

          "#{names.one? ? 'Permission Set' : 'Permission Sets'} #{names.join(', ')}"
        end

        # Why the column counts as personal data, when the finding says
        # (SensitiveColumns::Match#pattern: the GDPR pattern's alternative
        # that matched, or the host's filter_parameters); nothing otherwise.
        #
        # @return [String]
        def self.matched(finding)
          pattern = finding[:pattern]
          return '' if pattern.blank?

          pattern == SensitiveColumns::FILTER_PARAMETERS ? '; named by filter_parameters' : "; matches '#{pattern}'"
        end

        def initialize(report)
          @report = report
        end

        def to_s
          return CLEAN if @report.empty?

          ["GDPR audit found #{@report.size} issue(s):", *@report.map { |finding| "  #{line(finding)}" }].join("\n")
        end

        private

        def line(finding)
          LINES.fetch(finding[:type], FALLBACK).call(finding)
        end
      end
    end
  end
end
