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

      # A permission outcome with the sets that caused it. `muted_on`: each
      # blocking set => the Resource whose row blocks (a single-table-
      # inheritance base or the resource itself; the row nearest the
      # resource when the set has several), so a reason names the Resource
      # the set acts through (LabelsHelper#pf_chain_set_name).
      Outcome = Struct.new(:state, :granted_by, :blocked_by, :muted_on, keyword_init: true) do
        # The outcome of the granting sets and the blocking ones (set => Resource).
        def self.of(granted_by, muted_on)
          state = if granted_by.empty? then :none
                  elsif muted_on.any? then :blocked
                  else :granted
                  end
          new(state: state, granted_by: granted_by, blocked_by: muted_on.keys, muted_on: muted_on)
        end

        def granted? = state == :granted
        def blocked? = state == :blocked
      end

      # What one Permission Set does to a field: its most open level (a
      # granting set: masked, read or edit, with that row's mask strategy) or
      # what it takes away (a muting set: mask, hide or no_edit) —
      # Admin::FieldLevel names. `resource_name`: the Resource whose row
      # does it — the deciding entry's for a grant, the muting row's (an STI
      # base's or the resource's own) for a mute (field test round 8, B#38).
      FieldSource = Struct.new(:permission_set, :level, :mask_strategy, :resource_name, keyword_init: true)

      # `implicit` — no set configures the field for this outcome: it is a
      # declared virtual field on the implicit read + edit grant
      # (extra_fields_default_access = :grant).
      # `grants` / `mutes` — the FieldSources behind granted_by / blocked_by, same order:
      # the sets credited with what they did to the entry that decides.
      # `decided_by` — for a single-table-inheritance subclass, the base
      # Resource whose entry decides the field (ResourceChain: the strictest
      # entry along the chain); nil when the resource's own entry does.
      # `unreadable` — that entry does not grant Read, so it hides every field.
      # The level a field shows when a mute decides it (FieldSource#level of a
      # mute => Admin::FieldLevel granting level): hide => Hidden, mask =>
      # Masked, no_edit => Read-only.
      MUTED_LEVELS = { 'hide' => 'hidden', 'mask' => 'masked', 'no_edit' => 'read' }.freeze

      FieldOutcome = Struct.new(:name, :level, :mask_strategy, :granted_by, :blocked_by, :blocked_level,
                                :capped, :unconfigured, :virtual, :variant_of, :implicit, :grants, :mutes,
                                :decided_by, :unreadable, keyword_init: true) do
        def visible? = level != 'hidden'
        # Hidden because a Muting Permission Set takes it away, not because no set grants it.
        def hidden_by_muting? = level == 'hidden' && blocked_by.any?

        # The mutes that decide the field's level: the strongest mute's level
        # (blocked_level) when it is the level the field shows
        # (MUTED_LEVELS), and every set credited at it; none otherwise — a
        # mute that took editing away from a field a grant shows masked
        # changed the entry but does not decide what it shows. The row and
        # "Explain for" name these sets (review of round 8, D1/D2).
        #
        # @return [Array<FieldSource>]
        def deciding_mutes
          return [] unless blocked_level && MUTED_LEVELS[blocked_level] == level

          mutes.select { |source| source.level == blocked_level }
        end

        # Why the field is at its level: the one decision a person's
        # Effective access row, its Why panel and the field drawer's
        # "Explain for" all word (field test round 8, B#39) —
        # :muted (#deciding_mutes: a Muting Permission Set decides), :unconfigured, :granted,
        # :implicit (a virtual field's default), :unreadable (the deciding
        # entry does not grant Read), :inherited (an STI base's entry
        # decides and shows it to nobody) or :none (no set shows it).
        #
        # @return [Symbol]
        def reason
          return :muted if deciding_mutes.any?
          return :unconfigured if unconfigured
          return :granted if granted_by.any?
          return :implicit if implicit
          return :unreadable if unreadable

          decided_by ? :inherited : :none
        end
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
      # (ActivationConditions#never_grants?).
      def select_live_sets
        ids = PermissionForge::PermissionSetUser.where(user_id: @user.id).active_assignments.select(:permission_set_id)
        sets = PermissionForge::PermissionSet.active.where(id: ids).in_hash_order
                                             .includes(resources: %i[resource_fields resource_actions permission_set_rules])
                                             .reject(&:never_grants?)
        # Same row order as the hash builder (a variant tie goes to the older row).
        sets.each { |permission_set| PermissionForge::Services::PermissionHashBuilder.sort_rows(permission_set) }
      end

      def active_resources(permission_set)
        permission_set.resources.select(&:is_active)
      end

      # [permission_set, resource] for every active row of the sets named by
      # one of `names`, in set order, then in the order of `names` (a muting
      # set's row nearest the resource first), then row order.
      def pairs_for(permission_sets, names)
        permission_sets.flat_map do |ps|
          ChainEntries.in_chain_order(active_resources(ps), names).map { |resource| [ps, resource] }
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
      # block what some set granted, each set once (a muting set may reach an
      # entry through two rows: its first that blocks is named, pairs_for
      # puts the one nearest the resource first). The block gets the row and
      # whether it is a granting one.
      def outcome_for(grants, mutes)
        granted_by = grants.select { |_, resource| yield resource, true }.map(&:first).uniq
        blocking = granted_by.any? ? mutes.select { |_, resource| yield resource, false } : []
        Outcome.of(granted_by, blocking.group_by(&:first).transform_values { |rows| rows.first.last.name })
      end

      def rules_for(grants)
        grants.flat_map do |ps, resource|
          resource.permission_set_rules.select(&:is_active).map { |rule| RuleSource.new(rule: rule, permission_set: ps) }
        end
      end

      # --- Actions ----------------------------------------------------------

      def action_outcomes(sources)
        grants = sources.grants
        names = grants.flat_map { |_, r| r.resource_actions.select(&:is_active).map(&:name) }.uniq
        names.map { |action| [action, outcome_for(grants, sources.mutes) { |r, _granting| permitted?(r, action) }] }
      end

      def permitted?(resource, action)
        resource.resource_actions.any? { |row| row.is_active && row.is_permitted && row.name == action }
      end
    end
  end
end
