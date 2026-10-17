# frozen_string_literal: true

module PermissionForge
  # The one definition of "this column looks like personal data, and this is
  # the mask for it". Two sources, in this order: config.gdpr_field_patterns
  # (pattern => strategy; the alternative that matched names the match) and,
  # while filter_parameters_integration is on, the host application's
  # Rails filter_parameters (recommended strategy 'full': what the host hides
  # from its logs it does not show in the clear either).
  #
  # Every reader asks here: the admin's presets, "Sync fields", the Fields
  # tab and Home's privacy card; the field generator (ResourceFieldGenerator
  # and so the API's generate_fields and grant_full_access!) under
  # gdpr_defaults; GdprFieldAuditor (rake permission_forge:audit_masks) and
  # the security audit's personal_data check; the boot warning about
  # unmasked personal data. A column one of them calls personal data, they
  # all do (release_readiness/decision_parity_test.rb).
  #
  # @api private
  class SensitiveColumns
    # A match: `pattern` names what matched (the alternative of the GDPR
    # pattern, or 'filter_parameters'), `strategy` the recommended mask,
    # `source` :gdpr_pattern or :filter_parameters.
    Match = Struct.new(:pattern, :strategy, :source, keyword_init: true) do
      def filter_parameter? = source == :filter_parameters
    end

    FILTER_PARAMETERS = 'filter_parameters'

    # @param configuration [Configuration]
    # @param filter_parameters [Array, nil] the host's filter_parameters
    #   (default: Rails.application.config.filter_parameters while the
    #   integration is on)
    def initialize(configuration: PermissionForge.configuration, filter_parameters: nil)
      @configuration = configuration
      @filter_parameters = filter_parameters
    end

    # @param column_name [String, Symbol]
    # @return [Match, nil]
    def match(column_name)
      name = column_name.to_s
      regex, strategy = @configuration.gdpr_field_patterns.find { |pattern, _| name.match?(pattern) }
      return Match.new(pattern: pattern_label(regex, name), strategy: strategy, source: :gdpr_pattern) if regex
      return Match.new(pattern: FILTER_PARAMETERS, strategy: 'full', source: :filter_parameters) if filtered_parameter?(name)

      nil
    end

    # @param column_name [String, Symbol]
    # @return [Boolean]
    def sensitive?(column_name)
      !match(column_name).nil?
    end

    private

    # Human-ish pattern name for "Matches privacy pattern "email"": the
    # alternative of the regex that actually matched, stripped of anchors.
    def pattern_label(regex, name)
      source = regex.source
      hit = matching_alternative(source, name) || source.split('|').first
      hit.to_s.gsub(/\\[Azb]|\.\*|\[[^\]]*\]/, '').delete('^a-z0-9_').delete_prefix('_').delete_suffix('_').presence || source
    end

    def matching_alternative(source, name)
      source.split('|').find { |alt| safe_match?(alt, name) }
    end

    def safe_match?(source, name)
      name.match?(Regexp.new(source))
    rescue RegexpError
      false
    end

    # A column name is not a request parameter: ActiveSupport::
    # ParameterFilter matches a String / Symbol entry anywhere in the key,
    # so Rails' generated `:otp`, `:ssn`, `:salt` would call `footprint`,
    # `classname`, `persalted` personal data. Here such an entry names a
    # column when one of the name's segments (split on `_`) starts with it;
    # a leading or trailing underscore ties it to a segment boundary
    # (`_key`: a segment after the first starts with `key` — `api_key`, and
    # also `sort_key`). A Regexp entry matches as it is written; a Proc
    # entry (it rewrites values) names no column.
    def filtered_parameter?(name)
      @filter_patterns ||= host_filter_parameters.filter_map { |entry| filter_pattern(entry) }
      @filter_patterns.any? { |pattern| name.match?(pattern) }
    end

    def filter_pattern(entry)
      case entry
      when Regexp then entry
      when String, Symbol then segment_pattern(entry.to_s)
      end
    end

    def segment_pattern(entry)
      core = entry.delete_prefix('_').delete_suffix('_')
      return if core.empty?

      start = entry.start_with?('_') ? '(?<=_)' : '(?:\\A|(?<=_))'
      finish = entry.end_with?('_') ? '(?=_)' : ''
      Regexp.new("#{start}#{Regexp.escape(core)}#{finish}", Regexp::IGNORECASE)
    end

    def host_filter_parameters
      return [] unless @configuration.filter_parameters_integration
      return Array(@filter_parameters) if @filter_parameters
      return [] unless defined?(Rails) && Rails.application

      Array(Rails.application.config.filter_parameters)
    end
  end
end
