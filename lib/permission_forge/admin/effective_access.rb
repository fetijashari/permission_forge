# frozen_string_literal: true

module PermissionForge
  module Admin
    # "What can this person do right now, and why?"
    #
    # Mirrors PermissionHashBuilder + FieldPermissionMerger exactly (same set
    # selection order, same ||= / AND / muting semantics, same variants and
    # extra fields) but keeps provenance: which Permission Set granted or muted
    # every flag, field and action. Parity with the engine is covered by tests.
    #
    # Differences from a live request, by design:
    # - Activation conditions are not evaluated (the admin's IP/time says
    #   nothing about the person's). Conditional sets count, and are reported in
    #   #conditional_sets so the UI can say "only while conditions are true".
    class EffectiveAccess
      CRUD = %i[read_access create_access edit_access delete_access].freeze
      RESOURCE_FLAGS = (CRUD + %i[view_all modify_all]).freeze

      # A permission outcome with the sets that caused it.
      Outcome = Struct.new(:state, :granted_by, :blocked_by, keyword_init: true) do
        def granted? = state == :granted
        def blocked? = state == :blocked
      end

      # What one Permission Set does to a field: its most open level (a
      # granting set: masked, read or edit, with that row's mask strategy) or
      # what it takes away (a muting set: mask or hide) — Admin::FieldLevel names.
      FieldSource = Struct.new(:permission_set, :level, :mask_strategy, keyword_init: true)

      # `implicit` — no set configures the field for this outcome: it is a
      # declared virtual field on the implicit read + edit grant
      # (extra_fields_default_access = :grant).
      # `grants` / `mutes` — the FieldSources behind granted_by / blocked_by, same order:
      # the sets credited with what they did to the entry that decides.
      # `decided_by` — for a single-table-inheritance subclass, the base
      # Resource whose entry decides the field (ResourceChain: the strictest
      # entry along the chain); nil when the resource's own entry does.
      # `unreadable` — that entry does not grant Read, so it hides every field.
      FieldOutcome = Struct.new(:name, :level, :mask_strategy, :granted_by, :blocked_by, :blocked_level,
                                :capped, :unconfigured, :virtual, :variant_of, :implicit, :grants, :mutes,
                                :decided_by, :unreadable, keyword_init: true) do
        def visible? = level != 'hidden'
        # Hidden because a Muting Permission Set takes it away, not because no set grants it.
        def hidden_by_muting? = level == 'hidden' && blocked_by.any?
      end

      RuleSource = Struct.new(:rule, :permission_set, keyword_init: true)

      ResourceOutcome = Struct.new(:name, :flags, :records, :rules, :fields, :actions, keyword_init: true) do
        def op(flag) = flags.fetch(flag)
        def visible_field_count = fields.count(&:visible?)
      end

      # One resource name with its [permission_set, resource] pairs from the
      # granting and muting sets, the resulting resource flag outcomes and
      # the record rules that apply (its own entry's and, for a
      # single-table-inheritance subclass, its bases' — ResourceChain.rules).
      ResourceSources = Struct.new(:name, :grants, :mutes, :flags, :rules, keyword_init: true) do
        # View All / Modify All on this entry skips its own rules (ResourceChain.rules).
        def bypassed? = flags[:view_all].granted? || flags[:modify_all].granted?

        # :all when View All is granted and no rule applies (a base entry's
        # may, past the subclass's own bypass); :rules otherwise.
        def records
          return :none unless flags[:read_access].granted?

          flags[:view_all].granted? && rules.empty? ? :all : :rules
        end

        def outcome(fields:, actions:)
          ResourceOutcome.new(name: name, flags: flags, records: records, rules: rules, fields: fields, actions: actions)
        end
      end

      attr_reader :live_sets, :conditional_sets

      def self.call(...) = new(...).call

      def initialize(user:, configuration: PermissionForge.configuration, catalog: ModelCatalog.new)
        @user = user
        @configuration = configuration
        @catalog = catalog
      end

      # @return [Array<ResourceOutcome>]
      def call
        @live_sets = select_live_sets
        @conditional_sets = @live_sets.select(&:conditional?)
        granting, muting = @live_sets.partition(&:granting?)

        names = granting.flat_map { |ps| active_resources(ps).map(&:name) }.uniq
        names.map { |name| outcome_for_name(name, granting, muting) }
      end

      private

      # Same selection as PermissionCacheAccessor#active_non_expired_permission_sets
      # minus the request-context filter — a granting set whose condition
      # nobody can judge never passes it, so it is left out
      # (ConditionalSets::Member#never_grants?).
      def select_live_sets
        ids = PermissionForge::PermissionSetUser.where(user_id: @user.id).active_assignments.select(:permission_set_id)
        sets = PermissionForge::PermissionSet.active.where(id: ids).in_hash_order
                                             .includes(resources: %i[resource_fields resource_actions permission_set_rules]).to_a
        sets.reject! { |permission_set| permission_set.granting? && permission_set.conditions_broken? }
        # Same row order as the hash builder (a variant tie goes to the older row).
        sets.each { |permission_set| PermissionForge::Services::PermissionHashBuilder.sort_rows(permission_set) }
      end

      def active_resources(permission_set)
        permission_set.resources.select(&:is_active)
      end

      # [permission_set, resource] for every active row of the sets named by
      # one of `names`, in set order then row order.
      def pairs_for(permission_sets, names)
        permission_sets.flat_map do |ps|
          active_resources(ps).select { |r| names.include?(r.name) }.map { |resource| [ps, resource] }
        end
      end

      # The outcome for one resource name: its sources, the rules along its
      # chain (ResourceChain.names_for), then the fields — composed with the
      # entries of its bases the person has (ResourceChain.fields) — and
      # actions.
      def outcome_for_name(name, granting, muting)
        chain = PermissionForge::ResourceChain.names_for(name).map(&:to_s)
        sources = sources_for(name, granting, muting)
        sources.rules = rules_along(chain, granting, muting)
        bases = chain.drop(1).map { |base| sources_for(base, granting, muting) }.select { |base| base.grants.any? }
        build_resource(sources, bases)
      end

      # A granting set's row for the resource; a muting set's rows for the
      # resource and for the STI bases of the model it names — the engine's
      # cascade (PermissionHashBuilder#apply_muting_permission_set): a muted
      # base reaches the subclass entry, a muted subclass only itself.
      def sources_for(name, granting, muting)
        grants = pairs_for(granting, [name])
        mutes = pairs_for(muting, PermissionForge::ResourceChain.names_for(name).map(&:to_s))
        flags = RESOURCE_FLAGS.index_with { |flag| flag_outcome(grants, mutes, flag) }
        ResourceSources.new(name: name, grants: grants, mutes: mutes, flags: flags)
      end

      # The rules that apply to records of `chain.first` (ResourceChain.rules):
      # of every entry along the chain without a bypass of its own.
      def rules_along(chain, granting, muting)
        chain.flat_map do |name|
          sources = sources_for(name, granting, muting)
          sources.bypassed? ? [] : rules_for(sources.grants)
        end
      end

      # `bases`: the ResourceSources of the base entries the person has
      # (a granting row names them — the engine's entries), nearest first.
      def build_resource(sources, bases)
        fields = EffectiveFields.new(sources, configuration: @configuration, catalog: @catalog, bases: bases).call
        sources.outcome(fields: fields, actions: action_outcomes(sources))
      end

      # A resource flag: granted by the granting rows that grant it as the
      # engine reads them (PermissionHashBuilder.granted_flags — edit and
      # delete only with read, Modify All only with View All), blocked by the
      # muting rows that carry it.
      def flag_outcome(grants, mutes, flag)
        outcome_for(grants, mutes) do |resource, granting|
          granting ? PermissionForge::Services::PermissionHashBuilder.granted_flags(resource).fetch(flag) : resource.public_send(flag) == true
        end
      end

      # Granted by every granting set whose resource matches; muting sets only
      # block what some set granted. The block gets the row and whether it
      # is a granting one.
      def outcome_for(grants, mutes, &)
        granted_by = sets_matching(grants, true, &)
        blocked_by = granted_by.any? ? sets_matching(mutes, false, &) : []
        state = if granted_by.empty? then :none
                elsif blocked_by.any? then :blocked
                else :granted
                end
        Outcome.new(state: state, granted_by: granted_by, blocked_by: blocked_by)
      end

      # Each set once: a muting set may reach an entry through two rows.
      def sets_matching(pairs, granting)
        pairs.select { |_, resource| yield resource, granting }.map(&:first).uniq
      end

      def rules_for(grants)
        grants.flat_map do |ps, resource|
          resource.permission_set_rules.select(&:is_active).map { |rule| RuleSource.new(rule: rule, permission_set: ps) }
        end
      end

      # --- Actions ----------------------------------------------------------

      def action_outcomes(sources)
        grants = sources.grants
        names = grants.flat_map { |_, r| active_actions(r).map(&:name) }.uniq
        names.map { |action| [action, outcome_for(grants, sources.mutes) { |r, _granting| permitted?(r, action) }] }
      end

      def active_actions(resource)
        resource.resource_actions.select(&:is_active)
      end

      def permitted?(resource, action)
        active_actions(resource).select(&:is_permitted).map(&:name).include?(action)
      end
    end
  end
end
