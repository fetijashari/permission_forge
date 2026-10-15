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
      # `grants` / `mutes` — the FieldSources behind granted_by / blocked_by, same order.
      FieldOutcome = Struct.new(:name, :level, :mask_strategy, :granted_by, :blocked_by, :blocked_level,
                                :capped, :unconfigured, :virtual, :variant_of, :implicit, :grants, :mutes,
                                keyword_init: true) do
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
      # granting and muting sets, and the resulting resource flag outcomes.
      ResourceSources = Struct.new(:name, :grants, :mutes, :flags, keyword_init: true)

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
        names.map { |name| build_resource(sources_for(name, granting, muting)) }
      end

      private

      # Same selection as PermissionCacheAccessor#active_non_expired_permission_sets
      # minus the request-context filter.
      def select_live_sets
        ids = PermissionForge::PermissionSetUser.where(user_id: @user.id).active_assignments.select(:permission_set_id)
        sets = PermissionForge::PermissionSet.active.where(id: ids).order(:created_at, :id)
                                             .includes(resources: %i[resource_fields resource_actions permission_set_rules]).to_a
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

      # A granting set's row for the resource; a muting set's rows for the
      # resource and for the STI bases of the model it names — the engine's
      # cascade (PermissionHashBuilder#apply_muting_permission_set): a muted
      # base reaches the subclass entry, a muted subclass only itself.
      def sources_for(name, granting, muting)
        grants = pairs_for(granting, [name])
        mutes = pairs_for(muting, PermissionForge::ResourceChain.names_for(name).map(&:to_s))
        flags = RESOURCE_FLAGS.index_with { |flag| outcome_for(grants, mutes) { |r| r.public_send(flag) } }
        ResourceSources.new(name: name, grants: grants, mutes: mutes, flags: flags)
      end

      def build_resource(sources)
        grants = sources.grants
        ResourceOutcome.new(
          name: sources.name, flags: sources.flags,
          records: records_state(sources.flags),
          rules: rules_for(grants),
          fields: EffectiveFields.new(sources, configuration: @configuration, catalog: @catalog).call,
          actions: action_outcomes(grants, sources.mutes)
        )
      end

      # Granted by every granting set whose resource matches; muting sets only
      # block what some set granted.
      def outcome_for(grants, mutes, &)
        granted_by = sets_matching(grants, &)
        blocked_by = granted_by.any? ? sets_matching(mutes, &) : []
        Outcome.new(state: outcome_state(granted_by, blocked_by), granted_by: granted_by, blocked_by: blocked_by)
      end

      # Each set once: a muting set may reach an entry through two rows.
      def sets_matching(pairs)
        pairs.select { |_, resource| yield resource }.map(&:first).uniq
      end

      def outcome_state(granted_by, blocked_by)
        return :none if granted_by.empty?

        blocked_by.any? ? :blocked : :granted
      end

      def records_state(flags)
        return :none unless flags[:read_access].granted?

        flags[:view_all].granted? ? :all : :rules
      end

      def rules_for(grants)
        grants.flat_map do |ps, resource|
          resource.permission_set_rules.select(&:is_active).map { |rule| RuleSource.new(rule: rule, permission_set: ps) }
        end
      end

      # --- Actions ----------------------------------------------------------

      def action_outcomes(grants, mutes)
        names = grants.flat_map { |_, r| active_actions(r).map(&:name) }.uniq
        names.map { |action| [action, outcome_for(grants, mutes) { |r| permitted?(r, action) }] }
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
