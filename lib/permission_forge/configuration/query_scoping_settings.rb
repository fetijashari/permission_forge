# frozen_string_literal: true

module PermissionForge
  class Configuration
    # Query-scoping configuration (the three defense levels) extracted for SRP.
    #
    # Level 1 — ENFORCE:  auto_query_scoping applies filter-type row rules to
    #                     every relation built on a protected model.
    # Level 2 — DETECT:   unscoped_query_detection reports queries on protected
    #                     tables that bypassed a permission-scoped path.
    # Level 3 — DATABASE: database_row_level_security enables Postgres RLS
    #                     session-variable plumbing (policies via the
    #                     permission_forge:rls generator + rls:sync rake task).
    #
    # All options default OFF — behavior is unchanged unless a level is enabled.
    #
    # @api public
    module QueryScopingSettings
      AUTO_QUERY_SCOPING_VALUES = %i[off filter_only].freeze
      UNSCOPED_QUERY_DETECTION_VALUES = %i[off log raise].freeze
      # Columns a record rule never compares (PermissionForge::SecretColumns):
      # password digests, tokens, encrypted values, secrets.
      # Digests, tokens, encrypted values, secrets, then the credentials a
      # user table commonly has — passwords and their salts, API / private /
      # access keys, one-time-password seeds — anchored to name segments so
      # `owner_id`, `sort_key`, `secretary` or `crypto_wallet` are never caught.
      DEFAULT_RULE_SECRET_COLUMN_PATTERNS = [
        /\Apassword_digest\z/, /_digest\z/, /token/, /\Aencrypted_/, /_secret/, /passw/, /\Asecret(?:_|\z)/,
        /(?:\A|_)(?:api|private|secret|access)_key\z/, /(?:\A|_)crypted(?:_|\z)/, /(?:\A|_)salt\z/, /(?:\A|_)otp(?:_|\z)/
      ].freeze

      # Level 1 — ENFORCE.
      #   :off         — (default) only find_by/find_by!/permission_scoped apply rules
      #   :filter_only — a default_scope applies the current user's FILTER-type rules
      #                  to every relation (where/all/find/first/count/pluck and
      #                  association traversal). Join-type rules are NOT auto-applied
      #                  and still require permission_scoped (a boot warning fires
      #                  when join rules exist while this is enabled).
      # Notes: view_all/modify_all bypasses auto-scoping (parity with find_by);
      # nil current_user follows nil_user_strategy (:bypass -> unscoped,
      # :deny/:raise -> none — fail closed, never raising from inside a scope);
      # denied rows are silently filtered (find -> RecordNotFound).
      # Unknown values raise ConfigurationError at assignment (see below).
      attr_reader :auto_query_scoping

      # Level 2 — DETECT.
      #   :off   — (default) no detection
      #   :log   — Rails.logger.warn for each unscoped query on a protected table
      #   :raise — raise PermissionForge::UnscopedQueryError instead (CI guard)
      # Detection only activates in environments listed in
      # unscoped_query_detection_environments. Queries carrying the pf_scoped
      # annotation (permission_scoped, auto-scoping, gem internals) are never
      # flagged; INSERTs and schema queries are ignored.
      attr_reader :unscoped_query_detection

      # Environments (strings) where unscoped_query_detection is active.
      # Default: %w[development test]. Adding 'production' is allowed but a
      # boot warning fires when :raise is configured for production.
      attr_accessor :unscoped_query_detection_environments

      # Level 3 — DATABASE (Postgres only). When true, PermissionForge::RLS
      # helpers set/clear the session variable used by generated policies.
      # Policies themselves are installed via `rails generate permission_forge:rls`
      # and kept in sync with `rake permission_forge:rls:sync`.
      attr_accessor :database_row_level_security

      # Postgres session variable (set via SET LOCAL) that generated policies
      # read through current_setting(..., true). Must contain a dot (Postgres
      # requires namespaced custom settings).
      attr_accessor :rls_session_variable

      # The column names a record rule may not compare (PermissionForge::
      # SecretColumns, matched against the column name in lower case): a new
      # rule on one, or a change of a rule's column or path to one, is
      # refused, and the admin's rule builder does not offer them. Rules
      # stored before keep evaluating; the audit and Home list them. `[]`
      # opts out.
      attr_reader :rule_secret_column_patterns

      # @param patterns [Array<Regexp>]
      # @raise [ConfigurationError] for anything that is not a list of regular expressions
      def rule_secret_column_patterns=(patterns)
        unless patterns.is_a?(Array) && patterns.all?(Regexp)
          raise PermissionForge::ConfigurationError,
                "Invalid rule_secret_column_patterns: #{patterns.inspect}. Give a list of regular expressions ([] opts out)."
        end

        @rule_secret_column_patterns = patterns
      end

      def auto_query_scoping=(value)
        @auto_query_scoping = normalize_scoping_value(
          value, AUTO_QUERY_SCOPING_VALUES, 'auto_query_scoping'
        )
      end

      def unscoped_query_detection=(value)
        @unscoped_query_detection = normalize_scoping_value(
          value, UNSCOPED_QUERY_DETECTION_VALUES, 'unscoped_query_detection'
        )
      end

      def auto_query_scoping_enabled?
        @auto_query_scoping == :filter_only
      end

      def unscoped_query_detection_active?
        return false if @unscoped_query_detection == :off
        return false unless defined?(Rails) && Rails.respond_to?(:env)

        @unscoped_query_detection_environments.include?(Rails.env.to_s)
      end

      private

      def set_query_scoping_defaults
        @auto_query_scoping = :off
        @unscoped_query_detection = :off
        @unscoped_query_detection_environments = %w[development test]
        @database_row_level_security = false
        @rls_session_variable = 'permission_forge.user_id'
        @rule_secret_column_patterns = DEFAULT_RULE_SECRET_COLUMN_PATTERNS.dup
      end

      # Fail closed on typos: an unknown value must never silently enable a
      # weaker mode than the dev intended, so we raise at assignment time
      # (initializer) rather than guessing at query time.
      def normalize_scoping_value(value, allowed, option)
        sym = value.to_sym
        return sym if allowed.include?(sym)

        raise PermissionForge::ConfigurationError,
              "Invalid #{option}: #{value.inspect}. Allowed: #{allowed.map(&:inspect).join(', ')}"
      end
    end
  end
end
