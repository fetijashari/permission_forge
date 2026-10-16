# frozen_string_literal: true

module PermissionForge
  # The one definition of "a column that holds a secret", which a record rule
  # never compares: config.rule_secret_column_patterns (default
  # Configuration::QueryScopingSettings::DEFAULT_RULE_SECRET_COLUMN_PATTERNS —
  # `password_digest`, `*_digest`, `*token*`, `encrypted_*`, `*_secret*`;
  # `[]` opts out). A rule on such a column turns the rule into an oracle on
  # the secret (who may read which records tells its value apart), and the
  # rule's value (stored, shown in the admin and the API) would be a guess at it.
  #
  # Unlike SensitiveColumns (personal data, which a rule may well compare:
  # an owner's email) it judges the column a rule names: the name after the
  # last dot, in any case. Readers: PermissionSetRule's validation (a new
  # rule, or a change of its column or path), the admin's rule builder (not
  # offered), the security audit's secret_rule_columns finding and Home's
  # card for the rules stored before (they keep evaluating as before).
  #
  # @api private
  class SecretColumns
    # @param configuration [Configuration]
    def initialize(configuration: PermissionForge.configuration)
      @configuration = configuration
    end

    # @param name [String, Symbol, nil] a column name, qualified or not (`table.column`)
    # @return [Boolean]
    def secret?(name)
      !pattern_for(name).nil?
    end

    # @param name [String, Symbol, nil]
    # @return [Regexp, nil] the first pattern the column matches
    def pattern_for(name)
      column = name.to_s.split('.').last.to_s.downcase
      return if column.empty?

      Array(@configuration.rule_secret_column_patterns).find { |pattern| column.match?(pattern) }
    end

    # Whether the column a rule compares holds a secret.
    #
    # @param rule [PermissionSetRule]
    # @return [Boolean]
    def rule?(rule) = secret?(rule.field_name)
  end
end
