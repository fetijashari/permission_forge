# frozen_string_literal: true

module PermissionForge
  module Admin
    # Decides whether a column name looks like personal data, and which mask
    # strategy is recommended. Sources: config.gdpr_field_patterns (pattern =>
    # strategy) and, when filter_parameters_integration is on, the host app's
    # Rails filter_parameters (recommended strategy 'full').
    class SensitiveColumns
      Match = Struct.new(:pattern, :strategy, keyword_init: true)

      def initialize(configuration: PermissionForge.configuration, filter_parameters: nil)
        @configuration = configuration
        @filter_parameters = filter_parameters
      end

      # @return [Match, nil]
      def match(column_name)
        name = column_name.to_s
        regex, strategy = @configuration.gdpr_field_patterns.find { |pattern, _| name.match?(pattern) }
        return Match.new(pattern: pattern_label(regex, name), strategy: strategy) if regex
        return Match.new(pattern: 'filter_parameters', strategy: 'full') if filtered_parameter?(name)

        nil
      end

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

      def filtered_parameter?(name)
        filters = host_filter_parameters
        return false if filters.empty?

        @parameter_filter ||= ActiveSupport::ParameterFilter.new(filters)
        @parameter_filter.filter(name => 'x')[name] != 'x'
      end

      def host_filter_parameters
        return Array(@filter_parameters) if @filter_parameters
        return [] unless @configuration.filter_parameters_integration
        return [] unless defined?(Rails) && Rails.application

        Array(Rails.application.config.filter_parameters)
      end
    end
  end
end
