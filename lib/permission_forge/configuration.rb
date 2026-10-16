module PermissionForge
  # Raised for an invalid or missing setting, or an integration the host did not wire.
  #
  # @api public
  class ConfigurationError < StandardError; end

  # Every setting of the gem, set in a `PermissionForge.configure` block; the groups of options live in
  # `Configuration::*Settings` modules. Defaults are the library defaults; `config.preset` closes or restores them in one line.
  #
  # @api public
  class Configuration # rubocop:disable Metrics/ClassLength
    # User model class name (string, lazily constantized)
    attr_accessor :user_class

    # Lambda that returns the current user or nil
    attr_accessor :current_user_resolver

    # Lambda that checks if a user is active (receives user, returns boolean).
    # Read by the security audit (assignments held by inactive users); it does
    # not remove access by itself.
    attr_accessor :user_active_check

    # Lambda that returns an enumerable/AR relation of users eligible for
    # admin UI assignment dropdowns.
    #
    # Default: `user_model.order(:id)` — chosen because `:name` is often a
    # virtual attribute or a Ruby method (e.g., `"#{first_name} #{last_name}"`)
    # rather than a real column, so a SQL ORDER BY would fail.
    #
    # The User class must respond to `:name` and/or `:email` (or Rails 8's
    # `:email_address`), as method or column, for display labels. Override to scope or sort however you like:
    #   config.user_list_resolver = -> { User.active.order(:last_name, :first_name) }
    attr_accessor :user_list_resolver

    # Hard cap on how many users the admin UI assignment dropdowns render.
    # Applied on top of user_list_resolver (after excluding already-assigned
    # users), so an unscoped host users table can never turn a show page into
    # a six-figure <option> list. When the cap kicks in, the dropdown shows a
    # localized "first N users" hint prompting a narrower user_list_resolver.
    # A resolver relation carrying its own smaller LIMIT is preserved.
    # Default: 500. Set to nil to disable (not recommended for large tables).
    attr_accessor :user_list_limit

    # Lambda that formats a user for the assignment dropdown label.
    # Receives the user, returns a String (the human-readable part).
    # The combobox automatically appends ` #<id>` so the JS can extract the id.
    #
    # Default: tries name, full_name, display_name (in that order), then email
    # (or email_address), then a localized fallback. Override for full control:
    #   config.user_label_formatter = ->(u) { "#{u.last_name}, #{u.first_name} <#{u.email}>" }
    attr_accessor :user_label_formatter

    # Cache backend:
    #   :rails_cache       — uses Rails.cache (works with any Rails cache store:
    #                         redis_cache_store, solid_cache_store, mem_cache_store,
    #                         file_store, memory_store, etc.)
    #   :memory             — simple in-memory hash (good for dev/test, no dependencies)
    #   :null               — no caching (permissions recomputed every time)
    #   ActiveSupport::Cache::Store instance — use a specific cache store directly
    attr_accessor :cache_backend

    # Key prefix for cache entries (avoids collisions with other cached data)
    attr_accessor :cache_key_prefix

    # Cache TTL in seconds for permission entries. Cached permissions expire
    # after this duration as a staleness backstop — the cache is rebuilt
    # transparently on the next read (read-through), so a TTL never leaves a
    # user without permissions.
    # Default: 3600 (1 hour). Set to nil for no expiration (not recommended).
    attr_accessor :cache_ttl

    # Cache TTL in seconds applied when any of the user's permission sets has
    # activation conditions (session flag, IP allowlist, login hours). The
    # conditions are evaluated on every read, against the request that reads
    # (ConditionalSets); this clamps the base entry and its per-context
    # variants as a backstop. The effective TTL is
    # min(cache_ttl, conditional_set_cache_ttl).
    # Default: 300 (5 minutes). Set to nil to disable the clamp.
    attr_accessor :conditional_set_cache_ttl

    # Table name prefix for all permission_forge tables
    attr_accessor :table_name_prefix

    # Lambda that generates UUIDs
    attr_accessor :uuid_generator

    # Enable created_by_id/updated_by_id tracking
    attr_accessor :audit_trail_enabled

    # Class name for audit trail belongs_to associations
    attr_accessor :audit_user_class

    # Fields to ignore when auto-generating resource fields
    attr_accessor :ignored_fields

    # Hash of regex => lambda for field name variants
    # e.g. /_id\z/ => ->(name) { name.sub(/_id\z/, '_uuid') }
    attr_accessor :field_variant_mappings

    # Method name that models can define for extra permission fields
    attr_accessor :extra_fields_method

    # Lambda that builds the profile hash cached alongside permissions
    # Receives user, returns hash
    attr_accessor :profile_builder

    # Lambda that returns the current request context for activation conditions.
    # Returns a hash with optional keys: :ip, :session_flags, :time
    # Default: -> { {} } (no conditions — backward compatible)
    # Example: -> { { ip: Current.ip, session_flags: Current.session_flags, time: Time.current } }
    # Called on every permission read of a user who holds a conditional set:
    # keep it cheap, return {} (or anything with #to_h) where there is no
    # request, and never read permissions inside it (that raises
    # ConfigurationError).
    attr_accessor :request_context_resolver

    # How activation-condition sets (session flag / allowed_ips / login hours) are
    # treated when request_context_resolver returns a blank context.
    #   false (default) — treat conditional sets as active (backward compatible; a
    #                     boot warning fires so the fail-open is visible)
    #   true            — fail closed: with no request context (nothing, or neither
    #                     an IP nor session flags — a job, the console) conditional
    #                     GRANTING sets are dropped and conditional MUTING sets
    #                     still apply; with a context, a MUTING set whose
    #                     condition cannot be judged (no IP for allowed_ips, no
    #                     session_flags key for a flag) applies
    # Recommended: set to true.
    attr_accessor :conditional_sets_strict_mode

    # Multi-tenancy via acts_as_tenant (optional, nil = disabled).
    # Set to the tenant model class name (e.g., 'Account') to enable.
    # Requires the acts_as_tenant gem and a tenant column on all PF tables.
    # Boot raises ConfigurationError when this is set but the gem is not
    # loaded, so a misconfigured install can never run without isolation.
    # Rows whose tenant column is NULL are only visible while no tenant is
    # set (console, jobs); acts_as_tenant hides them under every tenant.
    attr_accessor :tenant_model

    # Foreign key column name for tenant association.
    # Default: inferred from tenant_model (e.g., 'Account' -> :account_id,
    # 'Billing::Account' -> :account_id)
    attr_accessor :tenant_column

    # Admin UI — HTTP Basic Auth (enabled by default, like Mission Control)
    # If enabled but credentials not set, returns 401 Unauthorized.
    # Set credentials via config or Rails credentials.
    attr_accessor :http_basic_auth_enabled
    # The admin UI's HTTP Basic username and password (see http_basic_auth_enabled).
    # @return [String, nil]
    attr_accessor :http_basic_auth_user, :http_basic_auth_password

    # Base controller class for admin UI (default: "::ActionController::Base")
    # Override to inherit from your own admin controller (e.g. "::AdminController")
    # which handles authentication via Devise, Warden, etc.
    attr_accessor :base_controller_class

    # JSON Admin API (disabled by default — opt-in)
    # When enabled, mounts RESTful JSON endpoints under /api/ within the engine.
    attr_accessor :api_enabled

    # Lambda that receives the controller instance and returns true/false for auth.
    # When nil and API enabled, all requests return 401 (safe default).
    # Example (PermissionForge.current_user is current_user_resolver's user, set when
    # api_base_controller_class signs the caller in): ->(_controller) { PermissionForge.current_user&.admin? }
    attr_accessor :api_auth

    # Base controller class for API controllers (default: "::ActionController::Base").
    # Override to inherit from your own base (e.g. "::Api::V1::Admin::BaseController").
    attr_accessor :api_base_controller_class

    # Lambda that paginates a scope: receives (scope, page, per_page) -> paginated scope.
    # When nil, a built-in LIMIT/OFFSET paginator is used.
    # Must respond to .total_count for meta. Example: ->(s, p, pp) { s.page(p).per(pp) }
    attr_accessor :api_pagination_handler

    # Maximum records per page for API collection endpoints.
    # Hard cap applied regardless of client-requested per_page.
    attr_accessor :api_max_per_page

    # Default records per page when per_page param is not provided.
    attr_accessor :api_default_per_page

    # When true (default), GET /api/stats answers only callers
    # api_stats_authorization allows (403 for everyone else). false: every
    # caller api_auth admits.
    attr_accessor :api_stats_require_admin

    # Lambda that receives the controller and decides who may read GET
    # /api/stats while api_stats_require_admin is on; a truthy answer allows.
    # When nil, stats are refused (until 0.16 an api_auth that sets @admin =
    # true on the controller still allows, with a deprecation warning).
    # Example: ->(controller) { PermissionForge.current_user&.admin? }
    attr_accessor :api_stats_authorization

    # Record identifier field for API lookups (default: :uuid).
    # Change to :id if your app uses integer IDs in URLs.
    attr_accessor :api_record_identifier

    # Hash of serializer overrides for API responses.
    # Keys are resource symbols, values are serializer classes.
    # Built-in serializers: respond to .new(record).as_json and .collection(records).
    # AMS serializers: also work — the base controller detects and adapts automatically.
    # Example: { permission_set: MyApp::PermissionSetSerializer }
    attr_accessor :api_serializer_overrides

    # When true, PermissionSetRuleSerializer replaces field_value with "[REDACTED]"
    # in API responses. Rule field_values can contain sensitive data (user IDs,
    # account numbers, business logic values). Enable for GDPR/HIPAA environments.
    # Default: false (backward-compatible)
    attr_accessor :api_redact_rule_field_values

    # Strategy when PermissionForge.current_user is nil in PermissionScopedFindable:
    #   :bypass — silent bypass, returns unscoped results (backward-compatible default)
    #   :raise  — raises NotAuthorizedError
    #   :deny   — returns nil (record not found)
    attr_accessor :nil_user_strategy

    # Lambda for action-level authorization on API mutation endpoints (clone, etc.).
    # Receives (controller, action_name, record) and should return true/false.
    # When nil, every mutation is refused while api_require_authorization is true (the default).
    # Example: ->(controller, action, record) { PermissionForge.current_user&.admin? }
    attr_accessor :api_action_authorization

    # Lambda for authorization checks on user-to-permission-set assignments
    # and group memberships. Receives (controller, target, user_ids): the
    # Permission Set (or Permission Set Group), and an Array of the people
    # concerned cast to the user model's primary-key type (Integers for
    # integer keys) on every endpoint. Returns true/false. When nil, the
    # request is refused while api_require_authorization is on (the default).
    attr_accessor :api_assignment_authorization

    # When true, API mutation and assignment endpoints REQUIRE an authorization
    # lambda to be configured: if api_action_authorization / api_assignment_authorization
    # is nil, the request is denied (403) instead of silently allowed. This closes
    # the "api_auth proves identity but not admin-ness" escalation, where any
    # authenticated caller could otherwise self-grant a permission set.
    #   true (default) — nil authorizer = deny
    #   false          — nil authorizer = allow: every caller api_auth lets in
    #                    may change permissions (opt-out; boot warning fires)
    attr_accessor :api_require_authorization

    # Optional callback when view_all/modify_all bypasses row-level rules.
    # Receives (user:, resource:, reason:). Errors are swallowed to prevent
    # callback failures from breaking queries.
    attr_reader :on_rule_bypass

    # I18n — available locales for the admin UI.
    # When set, only matching locale files are loaded (performance optimization).
    # When nil (default), falls back to PermissionForge::BUNDLED_LOCALES — the
    # locales the gem ships translations for ([:en, :sq, :mk]). Avoids the
    # admin UI rendering host-app locales (e.g. Faker) the gem can't translate.
    # Example: [:en, :sq, :mk]
    attr_accessor :available_locales

    # Optional callback for field-level audit logging.
    # Called for each field processed by FiltersResponseAttributes.
    # Receives: lambda(resource_name:, field_name:, action:, user:)
    # action is one of: :hidden, :masked, :passed
    attr_reader :on_field_filtered

    # Both hooks are subscribers of the runtime audit events
    # (Audit::Subscribers::LegacyHooks): setting one tells Audit::Gate.
    def on_rule_bypass=(hook)
      @on_rule_bypass = hook
      PermissionForge::Audit::Gate.changed! if defined?(PermissionForge::Audit::Gate)
    end

    def on_field_filtered=(hook)
      @on_field_filtered = hook
      PermissionForge::Audit::Gate.changed! if defined?(PermissionForge::Audit::Gate)
    end

    # Strategy for fields not mapped in the permission hash:
    #   :block        — exclude unmapped fields from response (secure default)
    #   :pass_through — field passes through unmasked (use only if all fields are explicitly mapped)
    #   :warn         — pass through but log a warning
    #   :mask_all     — apply full masking to unconfigured fields
    # Unknown values fall back to :block (fail closed).
    attr_accessor :unconfigured_field_strategy

    # How FiltersResponseAttributes behaves when there is no current user
    # (system/console/background context):
    #   :bypass — return attributes unfiltered (default, backward-compatible)
    #   :block  — return {} (strict fail-closed)
    # When a user IS present but has no configured access to the resource,
    # every field is routed through unconfigured_field_strategy regardless of
    # this setting (fail closed).
    attr_accessor :response_filter_nil_user_strategy

    # Custom mask strategies: Hash of strategy_name => callable(value)
    # Merged with built-in strategies in MaskValue.strategies
    attr_accessor :custom_mask_strategies

    # GDPR defaults: when true, ResourceFieldGenerator auto-masks fields
    # matching known GDPR-sensitive patterns (email, phone, name, address, etc.)
    attr_reader :gdpr_defaults

    # When true, raises ConfigurationError at boot if gdpr_defaults was never explicitly set.
    attr_accessor :gdpr_require_explicit_choice

    # When true, automatically appends GDPR field patterns to
    # Rails.application.config.filter_parameters during engine initialization.
    # This ensures sensitive fields (email, phone, SSN, etc.) are redacted in
    # Rails logs, error reporters, and parameter inspect output.
    # Default: true (enabled by default for security)
    attr_accessor :filter_parameters_integration

    # Hash of regex => strategy string for GDPR field pattern matching
    attr_reader :gdpr_field_patterns

    # Not created_at / updated_at (before 0.15 they were here): generated
    # fields give them a row, at most read-only on a granting set
    # (TimestampFields), so the default unconfigured_field_strategy (:block)
    # no longer hides them from a reader who is granted them.
    DEFAULT_IGNORED_FIELDS = %w[
      id token_digest token_last_digits
      created_by updated_by token password encrypted_password
      deleted_at uuid deactivated
    ].freeze

    DEFAULT_FIELD_VARIANT_MAPPINGS = {
      /_id\z/ => ->(name) { "#{name.sub(/_id\z/, '')}_uuid" },
      /_cents\z/ => ->(name) { name.sub(/_cents\z/, '') }
    }.freeze

    # Column names that are personal data, with the mask for each. One
    # definition for masking detection (ResourceFieldGenerator,
    # GdprFieldAuditor, SensitiveColumns, the security audit) and for
    # Rails' filter_parameters (PermissionForge.gdpr_filter_parameters), which
    # Rails also applies to ActiveRecord::Base.filter_attributes — so a match
    # prints as [FILTERED] in #inspect. A word matches anywhere in the name,
    # as Rails' own filter_parameter_logging does (`phone` in `cellphone`); a
    # stem short enough to sit inside an unrelated word (tel, city, zip, dob,
    # fax, mobile) matches a whole name segment (between `_`, the ends, a
    # digit or a camelCase capital) or the start of one: `telephone`,
    # `home_tel`, `tel2`, `telNumber`, `cityName`, `zipcode` yes — `hotel_id`,
    # `capacity`, `telemetry_enabled`, `automobile_id`, `gzip_enabled` no.
    # Every alternative stands alone (no group with an inner `|`):
    # SensitiveColumns names the one that matched. The first pattern
    # that matches decides the strategy: Rails 8's `email_address` is an
    # email (it also matches `address`, below).
    DEFAULT_GDPR_FIELD_PATTERNS = {
      /\Aemail\z|_email\z|\Aemail_address\z|_email_address\z/ => 'email',
      /phone|telefon|\Amobile|_mobile|\Afax|_fax|\Atel\z|\Atel_|\Atel[A-Z0-9]|_tel\z|_tel_|_tel[A-Z0-9]/ => 'last4',
      /\Assn\z|social_security|national_id/ => 'last4',
      /iban|bank_account|credit_card|card_number/ => 'last4',
      /\Aname\z|first_name|last_name|full_name|contact_name/ => 'first1_last4',
      /address|street|\Acity\z|\Acity_|\Acity[A-Z0-9]|_city\z|_city_|_city[A-Z0-9]|\Azip|_zip|postal/ => 'full',
      /date_of_birth|\Adob\z|\Adob_|\Adob[A-Z0-9]|_dob\z|_dob_|_dob[A-Z0-9]|birthday/ => 'full',
      /ip_address|\Aip\z/ => 'full',
      # Matched by accident before the short stems became whole segments
      # (`ethnicity` through `city`, `telegram_*` through `tel`); named here.
      /ethnic|telegram/ => 'full'
    }.freeze

    include GdprSettings
    include MaskedAttributesSettings
    include PermitsAttributesSettings
    include QueryScopingSettings
    include AdminUiSettings
    include VirtualAttributesSettings
    include ControllerActionSettings
    include CacheSettings
    include AuditSettings
    prepend StrategyValues
    # In front of StrategyValues: an option counts as set only once its value passed.
    prepend Presets

    def initialize
      @gdpr_defaults_explicitly_set = false
      set_preset_defaults
      set_core_defaults
      set_admin_defaults
      set_masked_attributes_defaults
      set_permits_attributes_defaults
      set_query_scoping_defaults
      set_admin_ui_defaults
      set_virtual_attributes_defaults
      set_controller_action_defaults
      set_cache_failure_defaults
      set_audit_defaults
    end

    # @return [Class] the class of `config.user_class`
    def user_model
      @user_class.constantize
    end

    # Whether klass is the user model (user_class) or one of its subclasses.
    # False when user_class names no class. The answer is kept per user_class
    # value and per class (by identity): a class reloaded in development is a
    # new object and is asked again; so is every class after user_class
    # changes.
    #
    # @param klass [Class, nil]
    # @return [Boolean]
    def user_model_class?(klass)
      return false unless klass.is_a?(Class)

      answers = (@user_model_answers ||= {})[@user_class] ||= {}.compare_by_identity
      answers.fetch(klass) do
        model = @user_class.to_s.safe_constantize
        answers[klass] = model.is_a?(Class) && klass <= model
      end
    end

    # Field-name variants produced by the configured mappings (e.g. `user_id`
    # -> `user_uuid`, `price_cents` -> `price`), whatever the model. What a
    # field row applies to is PermissionForge::FieldVariants: these, kept to
    # the names the Resource's model has (shared by the granting and muting
    # phases of PermissionHashBuilder and the admin).
    #
    # @param field_name [String, Symbol]
    # @return [Array<String>]
    def field_variants_for(field_name)
      name = field_name.to_s
      field_variant_mappings.filter_map do |pattern, transform|
        transform.call(name) if name.match?(pattern)
      end
    end

    # Returns an enumerable/AR relation of users for admin UI dropdowns.
    # Uses `user_list_resolver` when configured, otherwise falls back to
    # `user_model.order(:id)` — schema-agnostic because `:name` is frequently
    # a method or virtual attribute, not a real column.
    def user_list
      if @user_list_resolver
        @user_list_resolver.call
      else
        user_model.order(:id)
      end
    end

    # Convenience: returns user_list with the given ids excluded, capped at
    # user_list_limit. Works for both AR relations (where.not/limit) and plain
    # arrays (reject/first). Exclusion happens before the cap so assigned
    # users never consume dropdown slots.
    def assignable_users(exclude_ids: [])
      scope = user_list
      ids = Array(exclude_ids).compact
      if ids.any?
        scope = if scope.respond_to?(:where)
                  scope.where.not(id: ids)
                else
                  scope.reject { |u| ids.include?(u.id) }
                end
      end
      apply_user_list_limit(scope)
    end

    # @return [Class] the class of `config.audit_user_class` (who created or edited a row)
    def audit_user_model
      @audit_user_class.constantize
    end

    # @return [Cache::Base] the permission cache, built from the cache settings on first use
    def cache_store
      @cache_store ||= build_cache_store
    end

    # Drops the built cache store (the next read builds a new one) and retires every `permissions_hash` memo.
    # @return [void]
    def reset_cache_store!
      @cache_store = nil
      # A new store invalidates every instance-level permissions_hash memo:
      # memoized values were read from the store being discarded.
      PermissionForge.bump_permissions_cache_version!
      # ... and no invalidation is owed to it.
      PermissionForge::Cache::Invalidation.reset!
    end

    private

    # Caps the dropdown user list at user_list_limit.
    def apply_user_list_limit(scope)
      limit = user_list_limit
      return scope unless limit&.positive?
      return cap_relation_limit(scope, limit) if scope.respond_to?(:limit)
      return scope.first(limit) if scope.respond_to?(:first)

      scope
    end

    # An AR relation already carrying a smaller LIMIT (from user_list_resolver)
    # is left untouched — relation.limit(n) would silently WIDEN it.
    def cap_relation_limit(scope, limit)
      existing = scope.respond_to?(:limit_value) ? scope.limit_value : nil
      return scope if existing && existing <= limit

      scope.limit(limit)
    end

    def set_core_defaults
      set_user_defaults
      set_cache_defaults
      set_field_defaults
    end

    def set_user_defaults
      @user_class = 'User'
      @current_user_resolver = default_current_user_resolver
      @user_active_check = default_user_active_check
      @user_list_resolver = nil
      @user_list_limit = 500
      @user_label_formatter = nil
      @audit_trail_enabled = true
      @audit_user_class = 'User'
      @profile_builder = default_profile_builder
      @request_context_resolver = -> { {} }
      @conditional_sets_strict_mode = false
      @tenant_model = nil
      @tenant_column = nil
    end

    public

    def tenant_enabled?
      @tenant_model.present?
    end

    # Association acts_as_tenant declares on every permission model (e.g.
    # :account). Namespaces are dropped: `belongs_to :"billing/account"` is not
    # a valid association, so 'Billing::Account' also yields :account.
    def tenant_association_name
      return nil unless tenant_enabled?

      tenant_base_name.to_sym
    end

    # Foreign-key column acts_as_tenant filters on. Honours tenant_column,
    # otherwise "<association name>_id".
    def resolved_tenant_column
      return nil unless tenant_enabled?

      (@tenant_column || "#{tenant_base_name}_id").to_sym
    end

    private

    def tenant_base_name
      @tenant_model.to_s.demodulize.underscore
    end

    def set_cache_defaults
      @cache_backend = :memory
      @cache_key_prefix = 'pf'
      @cache_ttl = 3600
      @conditional_set_cache_ttl = 300
      @table_name_prefix = 'permission_forge_'
      @uuid_generator = -> { SecureRandom.uuid }
    end

    def set_field_defaults
      @ignored_fields = DEFAULT_IGNORED_FIELDS
      @field_variant_mappings = DEFAULT_FIELD_VARIANT_MAPPINGS.dup
      @extra_fields_method = :extra_fields_for_permissions
    end

    def set_admin_defaults
      set_ui_defaults
      set_gdpr_defaults
      set_api_defaults
    end

    def set_ui_defaults
      @http_basic_auth_enabled = true
      @http_basic_auth_user = nil
      @http_basic_auth_password = nil
      @base_controller_class = '::ActionController::Base'
      @on_field_filtered = nil
      @unconfigured_field_strategy = :block
      @response_filter_nil_user_strategy = :bypass
      @custom_mask_strategies = {}
      @available_locales = nil
      @nil_user_strategy = :bypass
      @on_rule_bypass = nil
    end

    def set_gdpr_defaults
      @gdpr_defaults = true
      @gdpr_require_explicit_choice = false
      @gdpr_field_patterns = DEFAULT_GDPR_FIELD_PATTERNS.dup
      @filter_parameters_integration = true
    end

    def set_api_defaults
      @api_enabled = false
      @api_auth = nil
      @api_base_controller_class = '::ActionController::Base'
      @api_stats_require_admin = true
      @api_stats_authorization = nil
      @api_pagination_handler = nil
      @api_max_per_page = 100
      @api_default_per_page = 15
      @api_record_identifier = :uuid
      @api_serializer_overrides = {}
      @api_action_authorization = nil
      @api_assignment_authorization = nil
      @api_require_authorization = true
      @api_redact_rule_field_values = false
    end

    def default_current_user_resolver
      -> { defined?(Current) ? Current.user : nil }
    end

    def default_user_active_check
      ->(user) { user.respond_to?(:active_for_authentication?) ? user.active_for_authentication? : true }
    end

    def default_profile_builder
      lambda { |user|
        {
          id: user.id,
          uuid: user.try(:uuid),
          # Raw-column-first (Admin::PersonLabel.raw_value): a masked User model never garbles the profile
          name: Admin::PersonLabel.raw_value(user, :name),
          # The first present of `email`, Rails 8's `email_address` (Admin::PersonLabel::EMAIL_ATTRIBUTES)
          email: Admin::PersonLabel.new(user).email
        }
      }
    end

    def build_cache_store
      case @cache_backend
      when :rails_cache
        PermissionForge::Cache::RailsCache.new(prefix: @cache_key_prefix)
      when :memory
        PermissionForge::Cache::MemoryCache.new(prefix: @cache_key_prefix)
      when :null
        PermissionForge::Cache::NullCache.new
      else
        if @cache_backend.is_a?(ActiveSupport::Cache::Store)
          PermissionForge::Cache::RailsCache.new(prefix: @cache_key_prefix, store: @cache_backend)
        else
          raise ArgumentError,
                "Unknown cache backend: #{@cache_backend.inspect}. " \
                'Use :rails_cache, :memory, :null, or pass an ActiveSupport::Cache::Store instance.'
        end
      end
    end
  end
end
