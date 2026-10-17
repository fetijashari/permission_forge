# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Configuration hardening: who can reach the admin, whether the cache is
      # shared, fail-closed flags, GDPR and audit settings, and the JSON API.
      class ConfigCheck < BaseCheck
        RULES = %i[
          admin_ui_exposed process_local_cache unconfigured_fields_pass write_protection_off nested_parent_fallback
          nil_user_bypass masked_nil_user_bypass gdpr_defaults_off log_filtering_off audit_trail_off conditional_sets_lenient
          detection_raises_in_production api_without_auth api_mutations_unguarded api_authorization_unset
          api_sequential_ids api_rule_values_exposed tenantless_admin strict_overrides
        ].freeze

        def call
          RULES.filter_map { |rule| send(rule) }
        end

        private

        def admin_ui_exposed
          return if configuration.http_basic_auth_enabled
          return unless configuration.base_controller_class.to_s.delete_prefix('::') == 'ActionController::Base'

          finding(:critical, :admin_ui_exposed, 'The admin UI has no authentication',
                  'http_basic_auth_enabled is false and base_controller_class is ActionController::Base, so ' \
                  'anyone who can reach the mount path can change permissions. Set base_controller_class to ' \
                  'a controller that authenticates and authorizes admins, or turn HTTP Basic back on.')
        end

        # The one definition of "process-local" is the store's own
        # (Cache::Base#process_local?: `cache_backend = :memory`, or
        # `Rails.cache` a `:memory_store`), asked of the store the reviewed
        # configuration builds.
        def process_local_cache
          return unless production? && configuration.cache_store.process_local?

          finding(:high, :process_local_cache, 'Permission cache is local to each process',
                  'The permission cache store lives in each process in production (cache_backend :memory, or ' \
                  'Rails.cache a :memory_store): a revoked permission stays cached in the other Puma workers until ' \
                  'cache_ttl, and an invalidation from a console, runner or rake task never reaches the servers. ' \
                  'Use :rails_cache with a shared store (Redis, Memcached, Solid Cache).')
        end

        def unconfigured_fields_pass
          strategy = configuration.unconfigured_field_strategy.to_s
          return unless %w[pass_through warn].include?(strategy)

          finding(:high, :unconfigured_fields_pass, 'Unconfigured fields are returned unfiltered',
                  "unconfigured_field_strategy is :#{strategy}, so a new column reaches filtered responses " \
                  'before anyone decides who may read it. Use :block (the default).')
        end

        def write_protection_off
          return unless configuration.masked_write_protection.to_s == 'off'

          finding(:high, :write_protection_off, 'Masked values can be written back',
                  'masked_write_protection is :off: saving a record that holds a masked value overwrites the ' \
                  'real data with the mask. Use :skip (default) or :raise.')
        end

        def nested_parent_fallback
          return unless configuration.nested_attributes_parent_fallback

          finding(:medium, :nested_parent_fallback, 'Nested attributes fall back to the parent resource',
                  'nested_attributes_parent_fallback is true: a `<assoc>_attributes` payload for a model the user ' \
                  "has no Resource entry for is filtered against the parent's fields, so a key editable on the parent " \
                  'admits the same key on a child the user was never granted. Configure the child Resource and set ' \
                  'it back to false (the default).')
        end

        def nil_user_bypass
          strategies = { nil_user_strategy: configuration.nil_user_strategy,
                         response_filter_nil_user_strategy: configuration.response_filter_nil_user_strategy }
          bypassing = strategies.select { |_, value| value.to_s == 'bypass' }.keys
          return if bypassing.empty?

          finding(:low, :nil_user_bypass, 'No current user means no permission checks',
                  "#{bypassing.join(' and ')} #{bypassing.one? ? 'is' : 'are'} :bypass. Make sure every request " \
                  'that touches protected models is authenticated first, or use :deny / :raise.')
        end

        # The one nil-user setting that is about the getters themselves.
        # :bypass is reported with :hide_in_requests as the remedy; under
        # :hide_in_requests what still reads as stored (jobs, the console) is
        # an info; :hide reports nothing here (UserModelCheck notes the user
        # model's exemption).
        def masked_nil_user_bypass
          case configuration.masked_attributes_nil_user_strategy
          when :bypass then masked_nil_user_bypassed
          when :hide_in_requests then masked_nil_user_outside_requests
          end
        end

        def masked_nil_user_bypassed
          finding(:medium, :masked_nil_user_bypass, 'Masked attributes are readable with no current user',
                  'masked_attributes_nil_user_strategy is :bypass: when nobody is signed in the getters, attributes ' \
                  'and as_json of a masked model return the stored values, whatever nil_user_strategy says — in a job, ' \
                  'a mailer or the console, and also in a web request where nobody is signed in (a public page, a ' \
                  'webhook, a controller that forgot authentication, a resolver that returns nil). Each such read in ' \
                  'a web request is logged (once per model and process) and published as field.unmasked_without_user ' \
                  '(stored when audit_runtime_events includes :bypass). Set it to :hide_in_requests: hidden in web ' \
                  'requests with nobody signed in, the stored values kept for jobs, rake and the console. Trade-off: ' \
                  'a page that reads a masked model before anyone signs in (a tenant lookup, a public page, a mail ' \
                  'sent with deliver_now) then reads hidden values: sign the request in first, or read raw columns ' \
                  'there. :hide hides everywhere (set the current user in jobs and mailers). The user model stays ' \
                  'readable under both, as sign-in needs.')
        end

        def masked_nil_user_outside_requests
          finding(:info, :masked_nil_user_outside_requests, 'Masked attributes are readable with no current user outside web requests',
                  'masked_attributes_nil_user_strategy is :hide_in_requests: in a web request with nobody signed in ' \
                  'every guarded attribute reads as hidden, but jobs, rake tasks, the runner and the console (and ' \
                  'Action Cable channel actions) read the stored values. That code runs on your servers, not on a ' \
                  'visitor\'s behalf; :hide hides there too, and then needs the current user set in those jobs and mailers.')
        end

        def gdpr_defaults_off
          return if configuration.gdpr_defaults

          finding(:medium, :gdpr_defaults_off, 'GDPR defaults are off',
                  'Generated fields for personal data are not masked by default. Set gdpr_defaults = true if ' \
                  'you hold EU personal data.')
        end

        def log_filtering_off
          return if configuration.filter_parameters_integration

          finding(:low, :log_filtering_off, 'Personal-data parameters are not filtered from logs',
                  'filter_parameters_integration is false. Enable it, or add ' \
                  'PermissionForge.gdpr_filter_parameters to Rails filter_parameters yourself.')
        end

        def audit_trail_off
          return if configuration.audit_trail_enabled

          finding(:medium, :audit_trail_off, 'Permission changes are not attributed',
                  'audit_trail_enabled is false, so permission records do not keep created_by / updated_by.')
        end

        def conditional_sets_lenient
          return if configuration.conditional_sets_strict_mode

          conditional = conditional_set_names
          return if conditional.empty?

          finding(:medium, :conditional_sets_lenient, 'Conditional sets apply when the request context is blank',
                  'conditional_sets_strict_mode is false: where the request context is blank (no resolver, or one ' \
                  'that returns {} in a job or the console), session-flag / IP / hours conditions are skipped and ' \
                  'the set applies, MFA- or IP-gated grants included.',
                  items: conditional)
        end

        def detection_raises_in_production
          return unless configuration.unscoped_query_detection.to_s == 'raise'
          return unless Array(configuration.unscoped_query_detection_environments).map(&:to_s).include?('production')

          finding(:medium, :detection_raises_in_production, 'Unscoped-query detection raises in production',
                  'unscoped_query_detection is :raise for production, so a missed scope becomes a 500 for users. ' \
                  'Use :log in production and :raise in test/CI.')
        end

        def api_without_auth
          return unless configuration.api_enabled && configuration.api_auth.nil?

          finding(:medium, :api_without_auth, 'The JSON API is enabled without api_auth',
                  'Every API request returns 401. Configure api_auth, or turn the API off.')
        end

        def api_mutations_unguarded
          return unless configuration.api_enabled && !configuration.api_require_authorization
          return if configuration.api_action_authorization && configuration.api_assignment_authorization

          finding(:high, :api_mutations_unguarded, 'Any authenticated API caller can change permissions',
                  'api_auth proves identity, not admin rights. Set api_action_authorization and ' \
                  'api_assignment_authorization, or keep api_require_authorization = true (the default) ' \
                  'to refuse changes until they are set.')
        end

        # Fails closed (each refusal is a 403 naming the option): a note, so
        # that the missing lambda is found before a caller is refused.
        def api_authorization_unset
          lines = PermissionForge::ApiAuthorizations.lines(configuration)
          return if lines.empty?

          finding(:info, :api_authorization_unset, 'The JSON API refuses what no authorization lambda guards',
                  'The API is on and api_auth admits callers, but an authorization lambda it needs is not set: it ' \
                  'answers 403 (naming the option) to everything that lambda guards. Set each one listed, or turn ' \
                  'the API off if nothing calls it.',
                  items: lines)
        end

        # Tenancy on, and an admin base controller that sets no tenant.
        def tenantless_admin
          defaults = configuration.default_admin_controllers_under_tenancy
          return if defaults.empty?

          names = defaults.join(' and ')
          if configuration.admin_tenantless_access_allowed?
            finding(:high, :tenantless_admin, 'The admin can read and change every tenant',
                    'tenant_model is set, admin_tenantless_access is :allow and ActionController::Base, which sets ' \
                    "no tenant, is still the base of #{names}: one admin request reads and changes the existing " \
                    'Permission Sets, assignments and audit log of every tenant. Point each at a controller that ' \
                    'sets the current tenant, and keep admin_tenantless_access :deny (the default).')
          else
            finding(:medium, :tenantless_admin, 'The admin base controllers set no tenant',
                    "tenant_model is set but ActionController::Base, which sets no tenant, is still the base of #{names}: " \
                    'every admin request without one is refused (admin_tenantless_access :deny) unless middleware ' \
                    'sets it. Point each at a controller that sets the current tenant.')
          end
        end

        def api_sequential_ids
          return unless configuration.api_enabled && configuration.api_record_identifier.to_s == 'id'

          finding(:low, :api_sequential_ids, 'The API exposes sequential ids',
                  'api_record_identifier is :id, which makes records easy to enumerate. Use :uuid.')
        end

        def api_rule_values_exposed
          return unless configuration.api_enabled && !configuration.api_redact_rule_field_values

          finding(:low, :api_rule_values_exposed, 'The API returns rule values',
                  'Rule field_value can hold user ids or business data. Set api_redact_rule_field_values = true ' \
                  'if that matters for your data.')
        end

        # Under the :strict preset, the options set looser than it (the
        # findings above rate the risk of each; this one names them all).
        def strict_overrides
          return unless configuration.preset == :strict

          looser = configuration.options_looser_than_strict
          return if looser.empty?

          finding(:low, :strict_overrides, 'Settings override the :strict preset',
                  "config.preset is :strict, but #{looser.size} #{looser.one? ? 'option is' : 'options are'} set " \
                  'to a looser value. Check that each override is intended.',
                  items: looser.map { |option, value| strict_override_item(option, value) })
        end

        def strict_override_item(option, value)
          strict = Configuration::Presets::STRICT.fetch(option)
          "#{option} = #{value.inspect} (strict: #{strict.inspect})"
        end

        def conditional_set_names
          PermissionForge::PermissionSet.active.conditional.order(:name).pluck(:name)
        end
      end
    end
  end
end
