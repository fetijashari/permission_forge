# frozen_string_literal: true

module PermissionForge
  module Admin
    # Read-only description of every configuration option for the Settings
    # page: section, value type, current vs default value, and security/privacy
    # risk. Friendly names and explanations live in the locale files under
    # permission_forge.settings.items.<key>.
    #
    # Values are never mutated here. Secrets are reported only as set/not set,
    # and code hooks (lambdas) only as default/custom/not set — never source.
    class SettingsCatalog # rubocop:disable Metrics/ClassLength -- DEFINITIONS is one line per configuration option
      Definition = Struct.new(:key, :section, :type, :options, :unit, :nil_label, :example, :ladder,
                              keyword_init: true)

      Row = Struct.new(:definition, :value, :default, :hook_state, :risk, keyword_init: true) do
        def key = definition.key
        def type = definition.type
        def changed? = value != default
        def warn? = risk == :warn
        def ok? = risk == :ok

        def recommended = RECOMMENDED[key]

        # The recommended value (risky rows) or the example (hooks, secrets,
        # names); nil when the snippet shows the current value.
        def snippet_override
          (recommended if warn?) || (definition.example if %i[hook secret names].include?(type))
        end
      end

      SECTIONS = %w[preset admin_access people field_protection masked_attributes record_rules controller_actions
                    activation_conditions privacy caching audit_trail multi_tenancy admin_api admin_ui database].freeze

      def self.d(key, section, type, **) = Definition.new(key: key.to_s, section: section, type: type, **)

      DEFINITIONS = [
        d(:preset, 'preset', :enum, options: Configuration::Presets::PRESETS.keys),

        d(:http_basic_auth_enabled, 'admin_access', :bool),
        d(:http_basic_auth_user, 'admin_access', :secret,
          example: 'Rails.application.credentials.dig(:permission_forge, :username)'),
        d(:http_basic_auth_password, 'admin_access', :secret,
          example: 'Rails.application.credentials.dig(:permission_forge, :password)'),
        d(:base_controller_class, 'admin_access', :class, example: "'::AdminController'"),
        d(:admin_assignment_authorization, 'admin_access', :hook,
          example: '->(controller, target, user_ids, action) { controller.current_user&.admin? }'),

        d(:user_class, 'people', :class, example: "'User'"),
        d(:current_user_resolver, 'people', :hook, example: '-> { ::Current.user if defined?(::Current) && ::Current.respond_to?(:user) }'),
        d(:user_active_check, 'people', :hook, example: '->(user) { user.active? }'),
        d(:user_list_resolver, 'people', :hook, nil_label: :default, example: '-> { User.order(:name) }'),
        d(:user_list_limit, 'people', :num, unit: :people),
        d(:user_label_formatter, 'people', :hook, nil_label: :default,
                                                  example: "->(user) { \"\#{user.name} <\#{user.email}>\" }"),
        d(:profile_builder, 'people', :hook, example: '->(user) { { id: user.id, name: user.name } }'),

        d(:unconfigured_field_strategy, 'field_protection', :enum, options: %i[block pass_through warn mask_all]),
        d(:response_filter_nil_user_strategy, 'field_protection', :enum, options: %i[bypass block]),
        d(:custom_mask_strategies, 'field_protection', :names,
          example: "{ 'iban_short' => ->(value) { value[0, 4] + ' **** ' + value[-4..] } }"),
        d(:ignored_fields, 'field_protection', :list),
        d(:field_variant_mappings, 'field_protection', :map),
        d(:extra_fields_method, 'field_protection', :str),
        d(:extra_fields_default_access, 'field_protection', :enum, options: %i[grant unconfigured]),
        d(:virtual_field_discovery, 'field_protection', :bool),
        d(:on_field_filtered, 'field_protection', :hook,
          example: '->(resource_name:, field_name:, action:, user:) { Rails.logger.info(...) }'),

        d(:auto_apply_masked_attributes, 'masked_attributes', :enum, options: %i[auto list off]),
        d(:masked_write_protection, 'masked_attributes', :enum, options: %i[skip raise off]),
        d(:masked_attributes_nil_user_strategy, 'masked_attributes', :enum, options: %i[bypass hide]),
        d(:hidden_attribute_value, 'masked_attributes', :str, nil_label: :nil),
        d(:omit_hidden_in_attributes_hash, 'masked_attributes', :bool),
        d(:mask_virtual_attributes, 'masked_attributes', :enum, options: %i[off auto list]),

        d(:nil_user_strategy, 'record_rules', :enum, options: %i[bypass deny raise]),
        d(:on_rule_bypass, 'record_rules', :hook, example: '->(user:, resource:, reason:) { Rails.logger.info(...) }'),
        d(:auto_query_scoping, 'record_rules', :enum, options: %i[off filter_only], ladder: 'enforce'),
        d(:unscoped_query_detection, 'record_rules', :enum, options: %i[off log raise], ladder: 'detect'),
        d(:unscoped_query_detection_environments, 'record_rules', :list),
        d(:database_row_level_security, 'record_rules', :bool, ladder: 'database'),
        d(:rls_session_variable, 'record_rules', :str),

        d(:controller_action_discovery, 'controller_actions', :bool),
        d(:controller_action_resolver, 'controller_actions', :hook,
          nil_label: :default, example: "->(path, action) { ['Customer', 'merge'] if path == 'customers/merges' }"),
        d(:controller_discovery_exclude, 'controller_actions', :list),
        d(:unconfigured_action_strategy, 'controller_actions', :enum, options: %i[allow block]),
        d(:action_guard_bypass, 'controller_actions', :hook, example: '->(user, _controller) { user.admin? }'),
        d(:action_guard_nil_user_strategy, 'controller_actions', :enum, options: %i[bypass deny], nil_label: :default),

        d(:request_context_resolver, 'activation_conditions', :hook,
          example: '-> { { ip: Current.ip, session_flags: Current.session_flags, time: Time.current } }'),
        d(:conditional_sets_strict_mode, 'activation_conditions', :bool),

        d(:gdpr_defaults, 'privacy', :bool),
        d(:gdpr_require_explicit_choice, 'privacy', :bool),
        d(:gdpr_field_patterns, 'privacy', :map),
        d(:filter_parameters_integration, 'privacy', :bool),

        d(:cache_backend, 'caching', :enum, options: %i[memory rails_cache null]),
        d(:cache_key_prefix, 'caching', :str),
        d(:cache_ttl, 'caching', :num, unit: :seconds),
        d(:conditional_set_cache_ttl, 'caching', :num, unit: :seconds),
        d(:snapshot_transactions, 'caching', :enum, options: %i[auto true false]),
        d(:on_cache_failure, 'caching', :hook,
          example: "->(operation:, user_id:, keys:, error:, **) { Sentry.capture_message(\"permission cache: \#{operation} failed\") }"),

        d(:audit_trail_enabled, 'audit_trail', :bool),
        d(:audit_user_class, 'audit_trail', :class, example: "'User'"),
        d(:audit_events, 'audit_trail', :enum, options: %i[auto true false]),
        d(:audit_actor_resolver, 'audit_trail', :hook, nil_label: :default,
                                                       example: '->(controller) { controller.current_user }'),
        d(:audit_request_context, 'audit_trail', :hook, nil_label: :default,
                                                        example: '->(controller) { { request_id: controller.request.request_id, ' \
                                                                 'ip: controller.request.remote_ip } }'),
        d(:audit_change_failure_strategy, 'audit_trail', :enum, options: %i[raise report log]),
        d(:audit_hook_failure_strategy, 'audit_trail', :enum, options: %i[report log raise]),
        d(:audit_runtime_events, 'audit_trail', :list),
        d(:audit_log_subscriber, 'audit_trail', :bool),
        d(:audit_retention_period, 'audit_trail', :num, unit: :seconds, nil_label: :nil),
        d(:audit_log_authorization, 'audit_trail', :hook, nil_label: :default,
                                                          example: '->(controller) { controller.current_user&.auditor? }'),

        d(:tenant_model, 'multi_tenancy', :class, nil_label: :disabled, example: "'Account'"),
        d(:tenant_column, 'multi_tenancy', :str, nil_label: :disabled),

        d(:api_enabled, 'admin_api', :bool),
        d(:api_auth, 'admin_api', :hook, example: '->(controller) { controller.current_user&.admin? }'),
        d(:api_base_controller_class, 'admin_api', :class, example: "'::Api::BaseController'"),
        d(:api_action_authorization, 'admin_api', :hook,
          example: '->(controller, action, record) { controller.current_user&.admin? }'),
        d(:api_assignment_authorization, 'admin_api', :hook,
          example: '->(controller, permission_set, user_ids) { controller.current_user&.admin? }'),
        d(:api_require_authorization, 'admin_api', :bool),
        d(:api_stats_require_admin, 'admin_api', :bool),
        d(:api_record_identifier, 'admin_api', :enum, options: %i[uuid id]),
        d(:api_default_per_page, 'admin_api', :num, unit: :records),
        d(:api_max_per_page, 'admin_api', :num, unit: :records),
        d(:api_pagination_handler, 'admin_api', :hook, nil_label: :default, example: '->(scope, page, per_page) { scope.page(page).per(per_page) }'),
        d(:api_serializer_overrides, 'admin_api', :map),
        d(:api_redact_rule_field_values, 'admin_api', :bool),

        d(:admin_model_resolver, 'admin_ui', :hook, nil_label: :default, example: '-> { [Customer, Invoice] }'),
        d(:admin_session_flags, 'admin_ui', :map),
        d(:admin_stale_assignment_days, 'admin_ui', :num, unit: :days),
        d(:admin_app_name, 'admin_ui', :str, nil_label: :default),
        d(:admin_back_url, 'admin_ui', :hook, nil_label: :default, example: "'/dashboard'"),
        d(:admin_docs_url, 'admin_ui', :str),
        d(:admin_tenantless_access, 'multi_tenancy', :enum, options: %i[deny allow]),

        d(:table_name_prefix, 'database', :str),
        d(:uuid_generator, 'database', :hook, example: '-> { SecureRandom.uuid }'),
        d(:available_locales, 'database', :list, nil_label: :default)
      ].freeze

      # Risk rules: key => ->(config) { :warn | :ok | nil }. Recommended values
      # (shown in the "How to change" snippet for risky rows) live in RECOMMENDED.
      RISKS = {
        'preset' => ->(config) { config.preset == :strict ? :ok : nil },
        'http_basic_auth_enabled' => lambda { |config|
          if config.http_basic_auth_enabled
            config.http_basic_auth_user.present? && config.http_basic_auth_password.present? ? :ok : :warn
          else
            default_controller?(config.base_controller_class) ? :warn : :ok
          end
        },
        'conditional_sets_strict_mode' => ->(config) { config.conditional_sets_strict_mode ? :ok : :warn },
        'admin_tenantless_access' => lambda { |config|
          next nil unless config.tenant_enabled?

          config.admin_tenantless_access_allowed? ? :warn : :ok
        },
        'api_require_authorization' => lambda { |config|
          next nil unless config.api_enabled
          next :ok if config.api_require_authorization
          next :ok if config.api_action_authorization && config.api_assignment_authorization

          :warn
        },
        'unconfigured_field_strategy' => ->(config) { config.unconfigured_field_strategy.to_s == 'pass_through' ? :warn : nil },
        'masked_write_protection' => ->(config) { config.masked_write_protection.to_s == 'off' ? :warn : :ok },
        'audit_trail_enabled' => ->(config) { config.audit_trail_enabled ? :ok : :warn },
        'audit_events' => ->(config) { AuditLog.recording_problem(config) ? :warn : :ok },
        'gdpr_defaults' => ->(config) { config.gdpr_defaults ? :ok : nil },
        'nil_user_strategy' => ->(config) { config.nil_user_strategy.to_s == 'bypass' ? nil : :ok },
        'masked_attributes_nil_user_strategy' => ->(config) { config.hide_masked_attributes_without_user? ? :ok : nil },
        'extra_fields_default_access' => ->(config) { config.grant_extra_fields_by_default? ? nil : :ok },
        'unconfigured_action_strategy' => ->(config) { config.allow_unconfigured_actions? ? nil : :ok },
        'action_guard_nil_user_strategy' => ->(config) { config.action_guard_nil_user_bypass? ? nil : :ok }
      }.freeze

      RECOMMENDED = {
        'conditional_sets_strict_mode' => 'true',
        'api_require_authorization' => 'true',
        'admin_tenantless_access' => ':deny',
        'unconfigured_field_strategy' => ':block',
        'masked_write_protection' => ':skip',
        'audit_trail_enabled' => 'true',
        'audit_events' => ':auto',
        'http_basic_auth_enabled' => 'true'
      }.freeze

      def self.default_controller?(name)
        name.to_s.delete_prefix('::') == 'ActionController::Base'
      end

      def initialize(configuration: PermissionForge.configuration, values: SettingsValues.new)
        @configuration = configuration
        @defaults = Configuration.new
        @values = values
      end

      def rows
        @rows ||= DEFINITIONS.map { |definition| build_row(definition) }
      end

      def row(key)
        rows.find { |r| r.key == key.to_s }
      end

      # [[section, [Row]]] in display order.
      def sections
        rows.group_by { |row| row.definition.section }.slice(*SECTIONS).to_a
      end

      def risky_rows
        rows.select(&:warn?)
      end

      def secure_count
        rows.count(&:ok?)
      end

      def recommended_value(key)
        row(key)&.recommended
      end

      # Ruby source for the right-hand side of `config.<key> = ...` in the
      # "How to change" snippet: the recommended value for risky rows,
      # otherwise the current value (or an example for hooks and secrets).
      def snippet_value(row)
        row.snippet_override || @values.ruby_literal(read(@configuration, row.key))
      end

      private

      def build_row(definition)
        key = definition.key
        value = @values.normalize(definition, read(@configuration, key))
        Row.new(definition: definition, value: value, default: @values.normalize(definition, read(@defaults, key)),
                hook_state: (value if definition.type == :hook), risk: RISKS[key]&.call(@configuration))
      end

      def read(config, key)
        config.respond_to?(key) ? config.public_send(key) : nil
      end
    end
  end
end
