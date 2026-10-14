# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Enforces row-level permission rules on including models.
    #
    # When a current user is set via {PermissionForge.current_user}, `find_by` and
    # `find_by!` apply the user's cached permission set rules before returning a
    # record, and `permission_scoped` returns a rule-constrained relation you can
    # chain (`.where`, `.first`, `.find`, `.count`, …). If view_all or modify_all
    # is enabled for the resource, rules are bypassed entirely.
    #
    # Level 1 — ENFORCE (config.auto_query_scoping = :filter_only): a
    # default_scope applies the current user's FILTER-type rules to every
    # relation built on the model (`where`, `all`, `find`, `first`, `count`,
    # `pluck`, association traversal). Join-type rules are NOT auto-applied and
    # still require `permission_scoped`. Denied rows are silently filtered
    # (`find` raises RecordNotFound); attributed denials (NotAuthorizedError
    # with rule messages) remain the job of `find_by` / `permission_scoped`.
    #
    # With auto-scoping :off (default), `find` (by primary key), bare `where`,
    # `first`, `all`, and association traversal are NOT auto-scoped — use
    # `find_by` / `find_by!` for single-record lookups, or start from
    # `Model.permission_scoped` to carry the rules through a query chain.
    # Level 2 (config.unscoped_query_detection) can log or raise on such
    # unscoped queries to help find and prevent them.
    #
    # Escape hatches: `PermissionForge.without_permission_scope { ... }`
    # (block-scoped, all levels) and `self.permission_forge_auto_scope = false`
    # (per-model opt-out of Level 1).
    #
    # Query building is delegated to {PermissionForge::Services::PermissionRuleApplier}.
    #
    # @example
    #   class Customer < ApplicationRecord
    #     include PermissionForge::Concerns::PermissionScopedFindable
    #   end
    #
    #   Customer.find_by(id: 1)                      # rules applied; nil if denied/missing
    #   Customer.find_by!(id: 1)                     # rules applied; raises if denied/missing
    #   Customer.permission_scoped.where(active: true).order(:name)  # rules carried through
    #
    # @api public
    module PermissionScopedFindable
      extend ActiveSupport::Concern

      include AutoPermissionScoping

      # SQL annotation marking a query as permission-scoped. Level 2 detection
      # treats any protected-table statement carrying this marker as compliant.
      SCOPED_ANNOTATION = 'pf_scoped'

      class << self
        # Names of models that include this concern. Level 2 detection resolves
        # the protected table set from this registry.
        #
        # @return [Set<String>]
        def protected_model_names
          @protected_model_names ||= Set.new
        end

        # Table names for all protected models, resolved lazily so that
        # table_name_prefix configuration and class reloading can't produce
        # stale names.
        #
        # @return [Array<String>]
        def protected_table_names
          protected_model_names.filter_map do |model_name|
            model_name.safe_constantize&.table_name
          end
        end
      end

      included do
        PermissionScopedFindable.protected_model_names << name if name

        # Per-model opt-out of Level 1 auto-scoping.
        class_attribute :permission_forge_auto_scope, default: true, instance_accessor: false

        # Level 1 — ENFORCE. Installed unconditionally at include time; every
        # enable/off decision happens INSIDE the block at query time (config is
        # read per relation build), so initializer-vs-model load order can never
        # leave a model silently unscoped. With auto_query_scoping :off the
        # block early-returns after two cheap reads.
        default_scope { pf_auto_permission_scope }

        class << self
          # `find_by` constrained by the current user's row-level rules.
          # @return [ActiveRecord::Base, nil] nil for a missing record
          # @raise [NotAuthorizedError] when a rule denies an existing record
          def find_by(*args)
            find_by_with_permission(*args)
          end

          # `find_by!` constrained by the current user's row-level rules.
          # @raise [ActiveRecord::RecordNotFound] for a missing record
          # @raise [NotAuthorizedError] when a rule denies an existing record
          def find_by!(*args)
            find_by_with_permission(*args) || raise(ActiveRecord::RecordNotFound)
          end
        end
      end

      # Raised when a row-level rule denies an existing record (find_by /
      # find_by!) or there is no user under nil_user_strategy :raise.
      #
      # `user` is the user the rules were applied for, `record_id` the id of
      # the record that was denied. `record` is nil when the gem raises: the
      # row the user may not see is not loaded to be handed out with the
      # error. All three are optional keywords; `NotAuthorizedError.new(details)`
      # and `raise NotAuthorizedError, details` work as before.
      #
      # `details` keeps whatever was raised with (the gem raises the Array of
      # rule failure messages; a Hash with :message for a missing user).
      # `message`, `to_s` and `full_message` are always a String, as every
      # error reporter and `rescue_from` handler expects: the failure
      # messages joined, the :message of a Hash, or the class name.
      #
      # @api public
      class NotAuthorizedError < StandardError
        # Why the lookup was refused.
        # @return [Hash, nil]
        attr_reader :details, :user, :record, :record_id

        NO_DETAILS = Object.new.freeze
        READERS = %i[user record record_id].freeze
        private_constant :NO_DETAILS, :READERS

        # The String a details value reads as.
        def self.text_for(details)
          case details
          when String then details
          when Array then details.map { |item| text_for(item) }.join(', ')
          when Hash then hash_text(details)
          else details&.to_s
          end
        end

        # The :message of a Hash, else the Hash without the user, record and
        # record_id keywords (a user's inspect must not land in an error
        # tracker), else nothing.
        def self.hash_text(details)
          text = text_for(details[:message] || details['message'])
          return text if text

          rest = details.except(*READERS)
          rest.to_s unless rest.empty?
        end
        private_class_method :hash_text

        # Keywords other than user:, record: and record_id: are details, as
        # they always were (`new(message: 'x')`); without a positional
        # argument every keyword given stays in details too, so a host's
        # `new(record: r, message: 'x')` reads as before.
        def initialize(details = NO_DETAILS, **keywords)
          @user, @record, @record_id = keywords.values_at(:user, :record, :record_id)
          if details.equal?(NO_DETAILS)
            details = keywords
          elsif !(extra = keywords.except(*READERS)).empty?
            raise ArgumentError, "unknown keyword(s): #{extra.keys.map(&:inspect).join(', ')}"
          end
          @details = details
          super(self.class.text_for(details))
        end
      end

      class_methods do
        def find_by_with_permission(*args)
          raise ArgumentError, 'wrong number of arguments (given 0, expected 1+)' if args.empty?

          host_suspended = AutoPermissionScoping.host_suspended?
          # The entire body runs with auto-scoping suspended: every internal
          # probe (rule application, the deny_or_missing existence check, the
          # final take) must see the un-auto-scoped relation — otherwise a
          # rule-denied row would look "missing" under Level 1 and find_by!
          # would raise RecordNotFound instead of NotAuthorizedError.
          pf_internally_unscoped do
            current_user = PermissionForge.current_user

            next handle_nil_user(*args, host_suspended: host_suspended) unless current_user

            rules = pf_applicable_rules(current_user, 'find_by')
            next tenant_safe_find_by(*args) unless rules

            query, failure_messages = PermissionForge::Services::PermissionRuleApplier.call(
              model_class: self, rules: rules, args: args, current_user: current_user
            )

            next deny_or_missing(failure_messages, current_user, *args) if failure_messages.any?

            query.where(*args).take
          end
        end

        # Returns a relation constrained by the current user's row-level rules, so
        # any further chaining (`.where`, `.first`, `.find`, `.count`) stays scoped.
        # Honors nil_user_strategy: :bypass -> all, :deny -> none, :raise -> raises.
        # view_all/modify_all and the no-rules case return the unconstrained relation.
        #
        # Built with auto-scoping suspended (rules are applied here explicitly —
        # including join-type rules — so the Level 1 filter-only scope must not
        # stack on top). The relation is resolved eagerly inside that window and
        # annotated as scoped, so lazy execution later stays correct and Level 2
        # detection recognizes it.
        #
        # @return [ActiveRecord::Relation]
        def permission_scoped
          host_suspended = AutoPermissionScoping.host_suspended?
          pf_internally_unscoped do
            build_permission_scope(host_suspended).annotate(SCOPED_ANNOTATION)
          end
        end

        private

        # The gem's own suspension of Level 1 (the queries find_by and
        # permission_scoped make while they apply the rules themselves): not
        # reported as a scope_suspended bypass, which is about the host's
        # PermissionForge.without_permission_scope.
        def pf_internally_unscoped(&)
          AutoPermissionScoping.internally_suspended(&)
        end

        def build_permission_scope(host_suspended)
          current_user = PermissionForge.current_user
          return permission_scoped_without_user(host_suspended) unless current_user

          rules = pf_applicable_rules(current_user, 'permission_scoped')
          return all unless rules

          PermissionForge::Services::PermissionRuleApplier.scope(
            model_class: self, rules: rules, current_user: current_user
          )
        end

        # Distinguishes "denied by a rule" from "no such record". find_by must honor
        # its nil contract for a genuinely missing record (matching stock Rails) and
        # only raise NotAuthorizedError when the record exists but rules deny it.
        def deny_or_missing(failure_messages, current_user, *args)
          relation = tenant_safe_relation.where(*args)
          return nil unless relation.exists?

          record_id = pf_denied_record_id(relation)
          PermissionForge::Audit::Runtime.denied(
            PermissionForge::Audit::Runtime::DENIED, reason: :rule, model: self, via: 'find_by',
                                                     user: current_user, record_id: record_id,
                                                     data: { 'messages' => failure_messages }
          )
          raise NotAuthorizedError.new(failure_messages, user: current_user, record_id: record_id)
        end

        # The id of the row the rules denied, for access.denied and the error:
        # read past the select, order and distinct of the relation (as exists?
        # reads it). Not read for a table without a single-column key, nor
        # under a grouping default scope.
        def pf_denied_record_id(relation)
          key = primary_key
          return unless key.is_a?(String) && relation.group_values.empty?

          relation.except(:select, :distinct, :order).pick(key)
        end

        def permission_scoped_without_user(host_suspended)
          return all if pf_suspended_by_host?(host_suspended, 'permission_scoped')
          return none if pf_nil_user_strategy('permission_scoped') == :deny

          Rails.logger&.warn('[PermissionForge] current_user is nil — permission_scoped returns unscoped relation')
          all
        end

        def handle_nil_user(*args, host_suspended:)
          return tenant_safe_find_by(*args) if pf_suspended_by_host?(host_suspended, 'find_by')
          return nil if pf_nil_user_strategy('find_by') == :deny

          Rails.logger&.warn('[PermissionForge] current_user is nil — bypassing row-level rules')
          tenant_safe_find_by(*args)
        end

        # Inside the host's PermissionForge.without_permission_scope block,
        # nobody signed in is trusted code that opted out in so many words: no
        # rules, whatever nil_user_strategy says (that strategy catches code
        # that forgot to set a user). Published as rule.bypassed,
        # scope_suspended.
        def pf_suspended_by_host?(host_suspended, via)
          return false unless host_suspended

          PermissionForge::Audit::Runtime.bypassed(:scope_suspended, model: self, via: via)
          true
        end

        # nil_user_strategy, reported: :raise raises, a denial (access.denied)
        # is :deny, anything else lets the query past the rules
        # (rule.bypassed) and is :bypass.
        def pf_nil_user_strategy(via)
          strategy = PermissionForge.configuration.nil_user_strategy
          unless %i[raise deny].include?(strategy)
            PermissionForge::Audit::Runtime.bypassed(:nil_user, model: self, via: via)
            return :bypass
          end

          PermissionForge::Audit::Runtime.denied(PermissionForge::Audit::Runtime::DENIED, reason: :nil_user, model: self, via: via)
          return :deny if strategy == :deny

          raise NotAuthorizedError, { message: I18n.t('permission_forge.errors.no_authenticated_user', default: 'No authenticated user') }
        end

        # The user's rules for this model — those of its own Resource entry
        # and of its STI ancestors' (ResourceChain) — or nil when none apply:
        # view_all or modify_all on every entry that has rules, or no rules —
        # which is reported as rule.bypassed (and, for view_all / modify_all,
        # to the legacy on_rule_bypass hook: Audit::Subscribers::LegacyHooks::RuleBypass).
        def pf_applicable_rules(current_user, via)
          rules, reason = PermissionForge::ResourceChain.rules(current_user, PermissionForge::ResourceChain.names(self))
          return rules unless reason

          PermissionForge::Audit::Runtime.bypassed(reason, model: self, via: via, user: current_user)
          nil
        end

        # where(...).take, which is what a relation's find_by does: never a
        # relation's find_by, which a Rails could route back through this
        # class's find_by (the override) and round in circles.
        def tenant_safe_find_by(*args)
          tenant_safe_relation.where(*args).take
        end

        # where(nil) preserves the model's default_scope (e.g. a soft-delete
        # `default_scope { where(deleted_at: nil) }`) AND acts_as_tenant's tenant
        # scope — unlike `unscoped`, which drops ALL scopes and would resurrect
        # soft-deleted / cross-tenant rows through PermissionForge's find_by.
        def tenant_safe_relation
          where(nil)
        end
      end
    end
  end
end
