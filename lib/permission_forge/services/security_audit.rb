# frozen_string_literal: true

module PermissionForge
  module Services
    # Read-only security review of a PermissionForge setup: configuration,
    # privileged grants, assignments, data integrity, record rules,
    # personal-data exposure and controller actions. Backs
    # `rake permission_forge:audit`.
    #
    # Each check is a class answering `#call` with an array of Finding,
    # listed by `SecurityAudit.checks` (config, privilege, assignment, rule,
    # integrity, activation conditions, personal data, controller actions,
    # the audit trail and the user model);
    # add one by passing `checks:` to `call` or by overriding `.checks`
    # (OCP). Nothing is ever changed.
    #
    # @example
    #   report = SecurityAudit.call
    #   report.counts            # => { critical: 0, high: 1, ... }
    #   report.at_least(:high)   # => [#<Finding ...>]
    #
    # @api public
    class SecurityAudit
      SEVERITIES = %i[critical high medium low info].freeze

      # @api private
      Finding = Struct.new(:check, :severity, :code, :title, :detail, :items, keyword_init: true) do
        def to_h = super.merge(items: items || [])
        def rank = SEVERITIES.index(severity)
      end

      # preset: the configuration's preset (:compat or :strict).
      #
      # @api private
      Report = Struct.new(:findings, :generated_at, :preset, keyword_init: true) do
        def counts = SEVERITIES.index_with { |severity| findings.count { |finding| finding.severity == severity } }

        # Findings of `severity` or worse. The name is read in any case
        # (:high, 'HIGH'); one that is not a severity counts as :info.
        def at_least(severity)
          limit = SEVERITIES.index(SecurityAudit.severity_named(severity)) || SEVERITIES.size
          findings.select { |finding| finding.rank <= limit }
        end

        def to_h = { generated_at: generated_at.iso8601, preset: preset, counts: counts, findings: findings.map(&:to_h) }
      end

      # The severity a name stands for, in any case and with surrounding
      # blanks ignored (`FAIL_ON=HIGH`, `' medium'`).
      #
      # @param name [String, Symbol, nil]
      # @return [Symbol, nil] one of SEVERITIES, nil for anything else
      def self.severity_named(name)
        wanted = name.to_s.strip.downcase
        SEVERITIES.find { |severity| severity.to_s == wanted }
      end

      # @return [Array<Class>] the check classes run by default
      def self.checks
        [
          SecurityAuditChecks::ConfigCheck, SecurityAuditChecks::PrivilegeCheck,
          SecurityAuditChecks::AssignmentCheck, SecurityAuditChecks::RuleCheck,
          SecurityAuditChecks::IntegrityCheck, SecurityAuditChecks::ConditionsCheck, SecurityAuditChecks::PersonalDataCheck,
          SecurityAuditChecks::ActionCheck, SecurityAuditChecks::AuditTrailCheck,
          SecurityAuditChecks::UserModelCheck
        ]
      end

      # Runs the read-only security review.
      # @return [Report]
      def self.call(...) = new(...).call

      def initialize(configuration: PermissionForge.configuration, checks: self.class.checks,
                     environment: defined?(Rails) ? Rails.env.to_s : 'development')
        @configuration = configuration
        @checks = checks
        @environment = environment
      end

      # @return [Report] the findings, most severe first
      def call
        findings = @checks.flat_map { |check| check.new(configuration: @configuration, environment: @environment).call }
        Report.new(findings: findings.sort_by(&:rank), generated_at: Time.current, preset: @configuration.preset)
      end
    end
  end
end
