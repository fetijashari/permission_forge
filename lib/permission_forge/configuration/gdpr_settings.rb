# frozen_string_literal: true

module PermissionForge
  class Configuration
    # GDPR-related configuration methods extracted for SRP.
    #
    # @api public
    module GdprSettings
      # Turns the GDPR masking defaults on or off (an explicit setting wins over a preset).
      # @param value [Boolean]
      def gdpr_defaults=(value)
        @gdpr_defaults_explicitly_set = true
        @gdpr_defaults = value
      end

      # Replaces the patterns that mark a field name as personal data.
      # @param patterns [Array<Regexp>]
      # @raise [ConfigurationError] for anything that is not a list of regular expressions
      def gdpr_field_patterns=(patterns)
        validate_gdpr_patterns!(patterns)
        @gdpr_field_patterns = patterns
      end

      def gdpr_defaults_explicitly_set?
        @gdpr_defaults_explicitly_set
      end

      # Remembers the digest of the current patterns (it tells a changed list from the default).
      # @return [String]
      # @api private
      def record_gdpr_pattern_checksum
        @gdpr_pattern_checksum = compute_pattern_checksum
      end

      def gdpr_patterns_changed_since_generation?
        return false unless @gdpr_pattern_checksum

        @gdpr_pattern_checksum != compute_pattern_checksum
      end

      def validate_gdpr_explicit_choice!
        return unless @gdpr_require_explicit_choice
        return if gdpr_defaults_explicitly_set?

        raise PermissionForge::ConfigurationError,
              'gdpr_require_explicit_choice is enabled but gdpr_defaults was not explicitly set. ' \
              'Please set config.gdpr_defaults = true or config.gdpr_defaults = false in your initializer.'
      end

      private

      def validate_gdpr_patterns!(patterns)
        return if patterns.blank?

        patterns.each_key do |key|
          next if key.is_a?(Regexp)

          Regexp.new(key)
        rescue RegexpError => e
          raise PermissionForge::ConfigurationError,
                "Invalid GDPR field pattern for '#{key}': #{e.message}"
        end
      end

      def compute_pattern_checksum
        Digest::SHA256.hexdigest(@gdpr_field_patterns.to_a.map { |k, v| "#{k.source}:#{v}" }.sort.join('|'))
      end
    end
  end
end
