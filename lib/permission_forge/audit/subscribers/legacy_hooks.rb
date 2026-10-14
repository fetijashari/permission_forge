# frozen_string_literal: true

module PermissionForge
  module Audit
    module Subscribers
      # The two hooks that existed before the audit event log, kept with the
      # call signatures they always had, as subscribers of the runtime events
      # that replaced them. Installed always and silenced while the hook is
      # nil, so a hook set at run time is called from then on.
      #
      # Alone (no other listener, the group not stored) they are handed the
      # decision without an event being built (Audit::Gate#direct_listeners):
      # a hook costs what it cost before the audit event log, roughly.
      #
      # A hook that raises no longer only logs: the failure follows
      # config.audit_hook_failure_strategy (:report by default — logged and
      # handed to Rails.error; :raise raises it).
      module LegacyHooks
        # config.on_rule_bypass(user:, resource:, reason: :view_all_or_modify_all)
        # — called when view_all or modify_all lets `find_by` / `find_by!` /
        # `permission_scoped` skip the row-level rules, as before. Not called
        # for auto-scoping (it would fire on every query) nor for the other
        # bypass reasons, which only rule.bypassed reports.
        class RuleBypass < Base
          REASONS = %w[view_all modify_all].freeze
          VIA = %w[find_by permission_scoped].freeze
          LEGACY_REASON = :view_all_or_modify_all

          def pattern = 'rule.bypassed.permission_forge'

          def light? = true

          def silenced?(_name)
            configuration.on_rule_bypass.nil?
          end

          private

          def deliver(_name, payload)
            hook = configuration.on_rule_bypass
            data = payload[:data]
            return unless hook && REASONS.include?(data['reason']) && VIA.include?(data['via'])

            guarded('rule.bypassed', :on_rule_bypass) do
              hook.call(user: payload[:objects][:user], resource: data['model'], reason: LEGACY_REASON)
            end
          end
        end

        # config.on_field_filtered(resource_name:, field_name:, action:, user:)
        # — called once for every field decision, in the order the decisions
        # were made, as before: one field.access event (a record read)
        # carries all of them in payload[:objects][:decisions]. Each call is
        # guarded on its own, so one that raises does not stop the others.
        class FieldFiltered < Base
          def pattern = 'field.access.permission_forge'

          def light? = true

          def silenced?(_name)
            configuration.on_field_filtered.nil?
          end

          # One decision, as it is made (Audit::FieldAccess::Direct).
          def deliver_decision(resource_name, field_name, action, user)
            hook = configuration.on_field_filtered
            return unless hook

            resource_name = resource_name.is_a?(Symbol) ? resource_name.name : resource_name.to_s
            guarded('field.access', :on_field_filtered) do
              hook.call(resource_name: resource_name, field_name: field_name, action: action, user: user)
            end
          end

          private

          def deliver(_name, payload)
            hook = configuration.on_field_filtered
            return unless hook

            Array(payload[:objects][:decisions]).each do |decision|
              next unless decision.hook

              guarded('field.access', :on_field_filtered) do
                hook.call(resource_name: decision.resource_name, field_name: decision.field_name,
                          action: decision.action, user: decision.user)
              end
            end
          end
        end
      end

      register(:on_rule_bypass, ->(_config) { LegacyHooks::RuleBypass.new.subscribe! })
      register(:on_field_filtered, ->(_config) { LegacyHooks::FieldFiltered.new.subscribe! })
    end
  end
end
