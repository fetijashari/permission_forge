# frozen_string_literal: true

module PermissionForge
  module Audit
    # The runtime decision events of the gem — what each one carries — for
    # the code that makes the decisions (PermissionScopedFindable,
    # AutoPermissionScoping, ControllerActionGuard, the services). Every
    # method returns at once, before anything is built, when the event is
    # neither stored nor heard (Audit.instrument?).
    #
    # Payloads name the model and the record by class (record_type: the base
    # class) and id only — never through a host record's readers, which a
    # masked model guards. The user the decision was made for is
    # subject_user_id, the actor is Actor.current (the request's actor), and
    # the live user object goes to in-process subscribers as
    # payload[:objects][:user].
    #
    # What happens on every query under auto-scoping is published at most once
    # per request (an executor run) per event, model, reason and user (#once?):
    # the memo lives in the request's isolated state (ExecutionState), never
    # on a record, is emptied with the audit context at the end of every
    # executor run that started without it (a request, a job) and by
    # Audit.reset!.
    #
    # @api private
    module Runtime
      BYPASSED = 'rule.bypassed'
      DENIED = 'access.denied'
      ACTION_DENIED = 'action.denied'
      UNSCOPED = 'query.unscoped'

      # Why row-level rules (or the action guard) did not apply.
      BYPASS_REASONS = %w[view_all modify_all nil_user scope_suspended auto_scope_opt_out no_rules guard_bypass].freeze

      # Asked on every relation built under auto-scoping.
      BYPASS_GATE = Gate.for(BYPASSED)

      ONCE_KEY = :pf_audit_runtime_once
      # A thread that never ends an executor run (a script, a daemon loop)
      # forgets what it published past this many keys.
      ONCE_LIMIT = 1_000

      class << self
        # rule.bypassed: the rules (or the guard) were skipped, and why.
        #
        # @param reason [String, Symbol] one of BYPASS_REASONS
        # @param model [Class, String] the model (or Resource name)
        # @param via [String] find_by, permission_scoped, auto_scope, rule_applier, action_guard
        # @param user [Object, nil] the user the decision was made for
        # @param once [Boolean] at most once per request
        # @param data [Hash] more event data (string keys)
        # @raise [ArgumentError] for a reason outside BYPASS_REASONS
        def bypassed(reason, model:, via:, user: nil, once: false, data: nil) # rubocop:disable Metrics/ParameterLists
          return unless BYPASS_GATE.open? && Audit.instrument?(BYPASSED)

          reason = reason.to_s
          raise ArgumentError, "unknown bypass reason #{reason.inspect} (#{BYPASS_REASONS.join(', ')})" unless BYPASS_REASONS.include?(reason)
          return if once && !once?(BYPASSED, model, reason, via, user)

          publish(BYPASSED, model: model, user: user, record_id: nil,
                            data: { 'reason' => reason, 'via' => via }.merge(data || {}))
        end

        # access.denied (rows of a model) or action.denied (a controller
        # action): the decision, why, and the record when it is known.
        #
        # @param event [String] DENIED or ACTION_DENIED
        # @param reason [String, Symbol] why (rule, nil_user, a guard reason)
        # @param model [Class, String]
        # @param via [String]
        # @param user [Object, nil]
        # @param record_id [Object, nil] the denied record's id, when known
        # @param once [Boolean] at most once per request
        # @param data [Hash] more event data (string keys)
        def denied(event, reason:, model:, via:, user: nil, record_id: nil, once: false, data: nil) # rubocop:disable Metrics/ParameterLists
          return unless Audit.instrument?(event)
          return if once && !once?(event, model, reason.to_s, via, user)

          publish(event, model: model, user: user, record_id: record_id,
                         data: { 'reason' => reason.to_s, 'via' => via }.merge(data || {}))
        end

        # query.unscoped: Level 2 detection saw a query on a protected table
        # that went past the rules. Once per request per table.
        #
        # @param model [Class, String, nil] the protected model, when known
        # @param table [String]
        # @param data [Hash]
        def unscoped(model:, table:, data: nil)
          return unless Audit.instrument?(UNSCOPED)
          return unless once?(UNSCOPED, model || table, table, nil, nil)

          user = current_user
          publish(UNSCOPED, model: model || table, user: user, record_id: nil, data: { 'table' => table }.merge(data || {}))
        end

        # permissions.rebuilt (the `cache` group): a user's permission hash
        # was built — read through on a cache miss, or asked for — and whether
        # it was withheld from the cache inside a transaction.
        def rebuilt(user, read_through:, withheld:)
          cache_event('permissions.rebuilt', user, 'read_through' => read_through, 'withheld' => withheld)
        end

        # permissions.invalidated (the `cache` group): a user's cached hash
        # was removed, for which tenant, whether the store confirmed it, and
        # the scope of the store (Cache::Report: `process_local`, and
        # `in_request` — which processes kept their entries when the store
        # lives in each process).
        def invalidated(user, tenant_id:, confirmed:)
          return unless Audit.instrument?('permissions.invalidated')

          scope = PermissionForge::Cache::Report.new
          cache_event('permissions.invalidated', user, 'tenant_id' => tenant_id, 'confirmed' => confirmed,
                                                       'process_local' => scope.process_local?, 'in_request' => scope.in_request?)
        end

        # Whether this is the first time in this request that `key` was
        # published; remembers it.
        def once?(*key)
          key[-1] = user_id(key[-1])
          seen = (state[ONCE_KEY] ||= {})
          return false if seen.key?(key)

          seen.clear if seen.size >= ONCE_LIMIT
          seen[key] = true
        end

        # Forgets what was published once (end of an executor run, tests).
        def reset!
          state.delete(ONCE_KEY)
        end

        # The user's id, read as its primary key; nil for no user or an
        # object that has none.
        def user_id(user)
          user.id if user.respond_to?(:id)
        end

        # The model's base class name (a Resource name as given).
        def record_type(model)
          return model.to_s unless model.is_a?(Class)

          model.respond_to?(:base_class) ? model.base_class.name : model.name
        end

        # The model's own name (a subclass stays itself).
        def model_name(model)
          model.is_a?(Class) ? model.name : model.to_s
        end

        private

        # Whose hash: record and subject are the user.
        def cache_event(event, user, data)
          return unless Audit.instrument?(event)

          Audit.instrument(event) do
            { record_type: record_type(user.class), record_id: user_id(user), subject_user_id: user_id(user), data: data,
              objects: { user: user } }
          end
        end

        def publish(event, model:, user:, record_id:, data:)
          Audit.instrument(event) do
            { record_type: record_type(model), record_id: record_id, subject_user_id: user_id(user),
              data: { 'model' => model_name(model) }.merge(data), objects: { user: user } }
          end
        end

        # A user the resolver raises for is no user here: the decision being
        # reported has been made already, and Actor.current reports the
        # resolver's failure when the event is built.
        def current_user
          PermissionForge.current_user
        rescue StandardError
          nil
        end

        def state
          ExecutionState
        end
      end
    end
  end
end
