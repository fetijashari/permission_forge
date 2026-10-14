# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Level 1 — ENFORCE (config.auto_query_scoping = :filter_only).
    #
    # Class methods backing the default_scope installed by
    # {PermissionScopedFindable}: every relation built on a protected model
    # applies the current user's FILTER-type rules automatically. Extracted
    # from PermissionScopedFindable for SRP — this module owns the auto-scope
    # decision tree, the host concern owns find_by/permission_scoped.
    #
    # Every path that lets a query past the rules while Level 1 is on is
    # published as rule.bypassed (scope_suspended, auto_scope_opt_out,
    # nil_user, view_all, modify_all, no_rules) and a nil user under :deny /
    # :raise as access.denied — at most once per request per model, reason
    # and user (Audit::Runtime.once?): this runs on every relation built.
    #
    # @api private
    module AutoPermissionScoping
      extend ActiveSupport::Concern

      # Set while the gem suspends Level 1 for its own queries
      # (internally_suspended): that suspension is not the host's, is not
      # reported, and gives nobody signed in no bypass.
      INTERNAL_SUSPENSION_KEY = :pf_internal_scope_suspension

      # Set while the default scope builds the rules (re-entrancy guard).
      IN_HOOK_KEY = :pf_in_auto_scope_hook

      # The gem's own suspension of the scoping, for the queries it makes for
      # itself and the host code they run (callbacks, default scopes): Level 1
      # and detection are off, as in the host's block, but it is not the
      # host's opt-out — not reported as scope_suspended, and nobody signed in
      # gets no bypass of nil_user_strategy. Both flags are :fiber slots of
      # ExecutionState, so they move together.
      def self.internally_suspended(&)
        PermissionForge::ExecutionState.with(INTERNAL_SUSPENSION_KEY, true) do
          PermissionForge.without_permission_scope(&)
        end
      end

      # @return [Boolean] whether the gem suspended the scoping for itself
      def self.internally_suspended?
        PermissionForge::ExecutionState[INTERNAL_SUSPENSION_KEY] == true
      end

      # @return [Boolean] whether the host suspended the scoping
      #   (PermissionForge.without_permission_scope), as opposed to the gem
      #   for its own queries
      def self.host_suspended?
        PermissionForge.scope_suspended? && !internally_suspended?
      end

      class_methods do
        # Level 1 hook body. Public because the default_scope block delegates
        # to the model class through Relation#method_missing (public dispatch).
        #
        # Every path taken while Level 1 is enabled annotates the relation as
        # scoped — including bypasses (view_all, no rules, nil-user :bypass):
        # the query went through the permission check, so Level 2 detection
        # must treat it as compliant and flag only true escapes
        # (unscoped, find_by_sql, raw SQL).
        #
        # @return [ActiveRecord::Relation]
        def pf_auto_permission_scope
          return all unless pf_auto_scope_applicable?
          # Re-entrancy guard: current_user_resolver or a permissions rebuild
          # may itself query a protected model — that inner query runs unscoped
          # (identity resolution precedes authorization) instead of recursing.
          return all.annotate(PermissionScopedFindable::SCOPED_ANNOTATION) if PermissionForge::ExecutionState[IN_HOOK_KEY]

          PermissionForge::ExecutionState.with(IN_HOOK_KEY, true) do
            pf_build_auto_scope.annotate(PermissionScopedFindable::SCOPED_ANNOTATION)
          end
        end

        private

        # The same three conditions as ever; the order only decides which
        # bypass is reported (none while Level 1 is off).
        def pf_auto_scope_applicable?
          return false unless PermissionForge.configuration.auto_query_scoping_enabled?

          if PermissionForge.scope_suspended?
            pf_auto_scope_bypassed(:scope_suspended) if AutoPermissionScoping.host_suspended?
            return false
          end
          return true if permission_forge_auto_scope

          pf_auto_scope_bypassed(:auto_scope_opt_out)
          false
        end

        def pf_auto_scope_bypassed(reason, user = nil)
          return unless PermissionForge::Audit::Runtime::BYPASS_GATE.open?

          PermissionForge::Audit::Runtime.bypassed(reason, model: self, via: 'auto_scope', user: user, once: true)
        end

        # The rules do not apply: reported, and the relation as it is.
        def pf_unscoped_by(reason, user)
          pf_auto_scope_bypassed(reason, user)
          all
        end

        def pf_build_auto_scope
          current_user = PermissionForge.current_user
          return pf_nil_user_auto_scope unless current_user

          # Resolve the rules once — permissions_hash is a cache read per
          # call, and this hook runs on every relation build: those of this
          # class's Resource entry and of its STI ancestors' (ResourceChain).
          # view_all/modify_all bypasses rules (parity with find_by). The
          # on_rule_bypass hook is deliberately NOT fired here — it would fire
          # on every query the user runs; rule.bypassed is, once per request.
          rules, bypass = PermissionForge::ResourceChain.rules(current_user, PermissionForge::ResourceChain.names(self))
          return pf_unscoped_by(bypass, current_user) if bypass

          rules = rules.select { |rule| pf_filter_rule?(rule) }
          return pf_unscoped_by(:no_rules, current_user) if rules.empty?

          # INVARIANT: PermissionRuleApplier builds from @model_class.where(nil),
          # which inside this default_scope block resolves against the in-flight
          # current_scope — preserving acts_as_tenant and any host default_scope
          # (soft-delete) in either declaration order. Never change the applier
          # to unscoped/fresh relations.
          PermissionForge::Services::PermissionRuleApplier.scope(
            model_class: self, rules: rules, current_user: current_user
          )
        end

        # Fail closed for :deny AND :raise — raising from inside a default_scope
        # would detonate in consoles, rake tasks, and view-layer counts, so the
        # strictest safe behavior is an empty relation (documented deviation).
        def pf_nil_user_auto_scope
          case PermissionForge.configuration.nil_user_strategy
          when :deny, :raise
            PermissionForge::Audit::Runtime.denied(PermissionForge::Audit::Runtime::DENIED, reason: :nil_user, model: self,
                                                                                            via: 'auto_scope', once: true)
            none
          else # :bypass
            pf_auto_scope_bypassed(:nil_user)
            all
          end
        end

        # Filter-type rules only: join-type rules inside a default_scope would
        # break includes/count/pluck and duplicate rows, so they remain the job
        # of permission_scoped (a boot warning fires when join rules exist while
        # Level 1 is enabled).
        def pf_filter_rule?(rule)
          PermissionForge::PermissionSetRule.filter_join_type?(rule[:join_type])
        end
      end
    end
  end
end
