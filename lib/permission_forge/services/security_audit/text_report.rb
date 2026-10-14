# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Plain-text rendering of a SecurityAudit::Report for terminals and logs.
      class TextReport
        def initialize(report)
          @report = report
        end

        def to_s
          [header, *@report.findings.map { |finding| section(finding) }, footer].join("\n\n")
        end

        private

        def header
          counts = @report.counts.map { |severity, count| "#{severity.to_s.capitalize}: #{count}" }.join(' · ')
          ["PermissionForge security audit — #{@report.generated_at.utc.iso8601}", preset, counts].compact.join("\n")
        end

        def preset
          case @report.preset
          when nil then nil
          when :compat then 'Preset: :compat (the library defaults; config.preset = :strict closes the fail-open ones)'
          else "Preset: #{@report.preset.inspect}"
          end
        end

        def section(finding)
          lines = ["[#{finding.severity.to_s.upcase}] #{finding.title}  (#{finding.check}/#{finding.code})",
                   "  #{finding.detail}"]
          lines.concat(Array(finding.items).map { |item| "    - #{item}" })
          lines.join("\n")
        end

        def footer
          return 'No findings.' if @report.findings.empty?

          'Read-only: nothing was changed. FORMAT=json for machine output; FAIL_ON=high to fail CI.'
        end
      end
    end
  end
end
