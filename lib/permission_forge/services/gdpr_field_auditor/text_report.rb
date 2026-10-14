# frozen_string_literal: true

module PermissionForge
  module Services
    class GdprFieldAuditor
      # Plain-text rendering of a GdprFieldAuditor report for terminals and
      # logs. One line per finding, whatever its type, so the count in the
      # header is the number of lines below it.
      #
      # @api private
      class TextReport
        CLEAN = 'All GDPR-sensitive fields are properly masked.'

        LINES = {
          unmasked_field: lambda { |finding|
            "[UNMASKED] #{finding[:resource_name]}.#{finding[:field_name]} " \
              "— matches pattern '#{finding[:suggested_strategy]}'"
          },
          unmapped_column: lambda { |finding|
            "[UNMAPPED] #{finding[:resource]}.#{finding[:column]} " \
              "— matches pattern '#{finding[:pattern_matched]}', no active ResourceField"
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
              '— unmasked here, masked in another Permission Set; a person in both sees the full value'
          }
        }.freeze

        # A finding type added to the auditor without a line here still prints.
        FALLBACK = lambda { |finding|
          "[#{finding[:type].to_s.upcase.tr('_', ' ')}] " \
            "#{finding.except(:type).map { |key, value| "#{key}: #{value}" }.join(', ')}"
        }

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
