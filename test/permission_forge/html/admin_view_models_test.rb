require 'test_helper'
require_relative '../sti_models'

module PermissionForge
  module Html
    # The read models behind the three heaviest admin templates: they decide
    # what a page shows, the template only draws it.
    class AdminViewModelsTest < ActiveSupport::TestCase
      setup do
        @set = create_permission_set(name: 'Sales rep')
        @resource = create_resource(permission_set: @set, read_access: true, edit_access: true)
      end

      def detail(name, resource: @resource, **context)
        resource = PermissionForge::Resource.find(resource.id)
        rows = PermissionForge::Admin::FieldRows.new(resource)
        PermissionForge::Admin::FieldDetail.new(resource: resource, row: rows.row(name), rows: rows, **context)
      end

      test 'a column nobody configured says what applies right now' do
        d = detail('domain')
        assert_equal :not_configured, d.unconfigured_note
        assert_equal 'unconfigured_field_strategy', d.unconfigured_setting
        assert_equal 'full', d.strategy
        assert_not d.locked?
      end

      test 'a configured field in force has no unconfigured note; one switched off does' do
        field = create_resource_field(resource: @resource, name: 'domain')
        assert_nil detail('domain').unconfigured_note
        field.update!(is_active: false)
        assert_equal :turned_off, detail('domain').unconfigured_note
      end

      test 'the privacy recommendation: offered, applied, or not shown in a muting set' do
        create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: false)
        d = detail('email')
        assert d.sensitive?
        assert d.recommendation_banner?
        assert_equal :apply, d.recommendation

        @resource.resource_fields.find_by(name: 'email').update!(mask_access: true, mask_strategy: d.row.match.strategy)
        assert_equal :applied, detail('email').recommendation

        muting = create_permission_set(name: 'Mute', is_muting: true)
        mres = create_resource(permission_set: muting, name: 'Customer')
        assert_not detail('email', resource: mres).recommendation_banner?
      end

      test 'a lock on the set, Resource or field locks the drawer and offers nothing to apply' do
        create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: false)
        @set.update_columns(is_editable: false)
        d = detail('email')
        assert d.locked?
        assert_nil d.recommendation
      end

      test 'a misspelt context key raises' do
        assert_raises(ArgumentError) { detail('domain', explain_user: 1) }
      end

      test 'the explain select starts on the person asked about' do
        user = create_user
        assert detail('domain', explain_user_id: user.id).explain_selected?(user)
        assert_not detail('domain').explain_selected?(user)
      end

      test 'an audit event splits into changes, snapshot and the rest' do
        event = PermissionForge::AuditEvent.new(event: 'resource_field.updated', actor_type: 'user', actor_id: '7',
                                                data: { 'changes' => { 'a' => [1, 2], 'b' => 3 }, 'snapshot' => { 'x' => 1 }, 'note' => 'n' })
        d = PermissionForge::Admin::AuditEventDetail.new(event, PermissionForge::Admin::AuditLookups.new([event]))
        assert_equal [['a', 1, 2], ['b', nil, 3]], d.change_rows
        assert_equal 2, d.changes_count
        assert_equal [['x', 1]], d.snapshot_rows
        assert_equal [%w[note n]], d.other_rows
        assert_not d.no_data?
        assert_not d.snapshot_of_removed?
      end

      test 'an event with no data, and one about a removal' do
        event = PermissionForge::AuditEvent.new(event: 'assignment.revoked', data: 'not a hash')
        d = PermissionForge::Admin::AuditEventDetail.new(event, nil)
        assert d.no_data?
        assert d.snapshot_of_removed?
        assert_empty d.change_rows
      end

      test 'the rule builder names the notes and choices' do
        form = PermissionForge::Admin::RuleForm.new(resource: @resource)
        builder = PermissionForge::Admin::RuleBuilder.new(form: form, resource: @resource, model_errors: 'oops')
        assert_equal %w[auto joins left_joins], builder.join_choices.map(&:join)
        assert_equal [true, false, false], builder.join_choices.map(&:checked)
        assert_not builder.advanced_open?
        assert_equal ['oops'], builder.model_errors
        assert_not builder.ignored_warning?
        @resource.update!(view_all: true)
        assert builder.ignored_warning?
      end

      # --- the WHY panel (people/_effective_why) --------------------------------
      #
      # EX: the explanation comes from the predicate that decided. For every
      # state a field of a person's effective access can be in, the panel's
      # level words are the entry's: the badge is the level the engine
      # enforces ("⊘ Hidden by muting" only when a Muting Permission Set took
      # away what a granting set gave), the deciding reason — the strongest
      # mute that changed the entry, else the most open grant — words the
      # entry's level (and, masked, its strategy), no grant is more open than
      # the one that decides, and every mute listed changed the entry.

      # name => [[:grant | :mute, level, options]] for the Customer email field.
      # A muting level nil adds the Resource row only; :no_edit is the row
      # with Edit alone (API / console).
      STI = 'PfStiBugTicket'.freeze
      WHY_STATES = {
        'hidden' => [[:grant, 'hidden']],
        'masked' => [[:grant, 'masked', { strategy: 'email' }]],
        'read' => [[:grant, 'read']],
        'edit' => [[:grant, 'edit']],
        'edit capped by the resource' => [[:grant, 'edit', { resource: { edit_access: false } }]],
        'read beats masked' => [[:grant, 'masked', { strategy: 'email' }], [:grant, 'read']],
        'masked in two strategies' => [[:grant, 'masked', { strategy: 'last4' }], [:grant, 'masked', { strategy: 'email' }]],
        'hidden and masked' => [[:grant, 'hidden'], [:grant, 'masked', { strategy: 'email' }]],
        'muted: hide' => [[:grant, 'read'], [:mute, 'hide']],
        'muted: mask' => [[:grant, 'read'], [:mute, 'mask']],
        'muted: mask on a masked field' => [[:grant, 'masked', { strategy: 'email' }], [:mute, 'mask']],
        'muted: no edit' => [[:grant, 'edit'], %i[mute no_edit]],
        'muted: no edit on a read-only field' => [[:grant, 'read'], %i[mute no_edit]],
        'muted: the resource read' => [[:grant, 'edit'], [:mute, nil, { resource: { read_access: true } }]],
        'muted: the resource edit' => [[:grant, 'edit'], [:mute, nil, { resource: { edit_access: true } }]],
        'muted: mask on a field nobody shows' => [[:grant, 'hidden'], [:mute, 'mask']],
        'muted: hide on a field nobody shows' => [[:grant, 'hidden'], [:mute, 'hide']],
        'muted: mask, then hide' => [[:grant, 'edit'], [:mute, 'mask'], [:mute, 'hide']],
        'muted: no edit, then mask' => [[:grant, 'edit'], %i[mute no_edit], [:mute, 'mask']],
        'not configured' => [[:grant, nil]],
        # Single-table inheritance (review R4 P1-2): the subclass's field is
        # composed with its base's (ResourceChain); `on:` names the Resource
        # of a row (default: the subclass). A mute is credited only when the
        # granting sets alone would show the field.
        'sti: base hidden, subclass read, hidden by a mute on the subclass' =>
          [[:grant, 'hidden', { on: 'PfStiTicket' }], [:grant, 'read', { on: STI }], [:mute, 'hide', { on: STI }]],
        'sti: muted base read, the subclass field hidden by its own grant' =>
          [[:grant, 'read', { on: 'PfStiTicket' }], [:grant, 'hidden', { on: STI }],
           [:mute, nil, { on: 'PfStiTicket', resource: { read_access: true } }]],
        'sti: both read, hidden by a mute on the subclass' =>
          [[:grant, 'read', { on: 'PfStiTicket' }], [:grant, 'read', { on: STI }], [:mute, 'hide', { on: STI }]],
        'sti: muted base read reaches a readable subclass field' =>
          [[:grant, 'read', { on: 'PfStiTicket' }], [:grant, 'read', { on: STI }],
           [:mute, nil, { on: 'PfStiTicket', resource: { read_access: true } }]],
        'sti: base read-only, subclass editable, no edit muted on the subclass' =>
          [[:grant, 'read', { on: 'PfStiTicket' }], [:grant, 'edit', { on: STI }], [:mute, :no_edit, { on: STI }]],
        'sti: base masked, subclass read' =>
          [[:grant, 'masked', { on: 'PfStiTicket', strategy: 'email' }], [:grant, 'read', { on: STI }]]
      }.freeze

      test 'every WHY level word equals the level the hash entry gives, for every state' do
        failures = WHY_STATES.flat_map do |state, rows|
          user = create_user
          sets = rows.each_with_index.map { |row, index| why_set(state, index, *row) }
          sets.each { |set| create_permission_set_user(user: user, permission_set: set) }
          why_failures(state, user, sets, rows.any? { |row| row[2]&.key?(:on) } ? STI : 'Customer')
        end

        assert_empty failures, failures.join("\n")
      end

      private

      def why_set(state, index, kind, level, options = {})
        set = create_permission_set(name: "#{state} #{index}", is_muting: kind == :mute, created_at: (10 - index).minutes.ago)
        resource = create_resource(permission_set: set, name: options.fetch(:on, 'Customer'), read_access: kind == :grant,
                                   edit_access: kind == :grant, **options.fetch(:resource, {}))
        flags = why_flags(kind, level)
        create_resource_field(resource: resource, name: 'email', mask_strategy: options.fetch(:strategy, 'full'), **flags) if flags
        set
      end

      def why_flags(kind, level)
        return if level.nil?
        return { read_access: false, edit_access: true, mask_access: false } if level == :no_edit

        PermissionForge::FieldLevel.flags_for(level, muting: kind == :mute)
      end

      # The engine's resource entry for the sets, in the order a request
      # merges them; for a subclass, its field composed along the chain as
      # the attribute guard composes it (ResourceChain.compose_field).
      def why_engine(user, sets, name) # rubocop:disable Metrics/AbcSize -- the hash, then the chain's composition
        ordered = PermissionForge::PermissionSet.where(id: sets.map(&:id)).in_hash_order.to_a
        resources = PermissionForge::Services::PermissionHashBuilder.call(user: user, permission_sets: ordered)[:resources]
        return resources[name] if name == 'Customer'

        resources = resources.deep_symbolize_keys # as the stored hash the guard reads
        entries = PermissionForge::ResourceChain.names_for(name).filter_map { |chain_name| resources[chain_name].presence }
        email = PermissionForge::ResourceChain.compose_field(entries, :email)
        { permissions: resources.dig(name.to_sym, :permissions) || {}, fields: email ? { 'email' => email } : {} }
      end

      def why_field(user, name)
        PermissionForge::Admin::EffectiveAccess.call(user: user).find { |res| res.name == name }
                                               .fields.find { |outcome| outcome.name == 'email' }
      end

      def why_failures(state, user, sets, name)
        engine = why_engine(user, sets, name)
        field = why_field(user, name)
        return (field.unconfigured ? [] : ["#{state}: configured, the engine has no entry"]) unless engine[:fields]['email']

        before = why_engine(user, sets.reject(&:is_muting), name)[:fields]['email']
        WhyCheck.new(field, engine, before).problems.map { |problem| "#{state}: #{problem}" }
      end

      # One field's WHY panel against the engine's entry for it (`before`:
      # the entry the granting sets alone give).
      class WhyCheck
        # What a mute that decides makes of the entry.
        MUTE_LEVELS = { 'hide' => 'hidden', 'mask' => 'masked', 'no_edit' => 'read' }.freeze
        LEVEL = PermissionForge::FieldLevel

        def initialize(field, engine, before)
          @field = field
          @entry = engine[:fields]['email']
          @before = before || {}
          @level = LEVEL.effective_level(@entry)
          @capped = @level == 'edit' && !engine[:permissions][:edit_access]
        end

        def problems
          badge_problems + deciding_problems + order_problems + mute_problems
        end

        private

        def badge_problems
          muted = @level == 'hidden' && LEVEL.effective_level(@before) != 'hidden'
          expected = if muted
                       I18n.t('permission_forge.ui.states.effective.hidden_by_muting')
                     else
                       I18n.t("permission_forge.ui.states.field_level.#{@capped ? 'read' : @level}")
                     end
          problems = []
          problems << "badge #{badge}, the entry gives #{expected}" unless badge == expected
          problems << "capped #{@field.capped}, expected #{@capped}" unless @field.capped == @capped
          problems
        end

        # The badge's words, as the panel draws them.
        def badge
          Nokogiri::HTML.fragment(PermissionForge::ApplicationController.helpers.pf_effective_field_badge(@field)).text
                        .sub(/\A\S+ /, '').sub(/ \(.*\z/, '')
        end

        def deciding_problems
          mute = @field.mutes.first
          return ["the deciding mute says #{mute.level}, the entry is #{@level}"] if mute && MUTE_LEVELS[mute.level] != @level
          return [] if mute
          return @field.grants.any? ? ["hidden by no mute, yet #{@field.grants.map(&:level)} grant"] : [] if @level == 'hidden'

          grant_problems(@field.grants.first)
        end

        def grant_problems(first)
          return ["the deciding grant says #{first&.level.inspect}, the entry is #{@level}"] unless first&.level == @level
          return [] unless @level == 'masked' && first.mask_strategy != @entry[:mask_strategy]

          ["masked #{first.mask_strategy}, the entry #{@entry[:mask_strategy]}"]
        end

        def order_problems
          top = LEVEL.rank(@field.grants.first&.level)
          above = @field.grants.select { |grant| LEVEL.rank(grant.level) > top }
          problems = above.map { |grant| "grant #{grant.level} above the deciding one" }
          problems << 'blocked_by is not the mutes' unless @field.blocked_by == @field.mutes.map(&:permission_set)
          problems
        end

        def mute_problems
          @field.mutes.reject { |mute| changed?(mute.level) }.map { |mute| "mute #{mute.level} changed nothing" }
        end

        def changed?(mute_level) # rubocop:disable Metrics/CyclomaticComplexity -- one rule per mute level
          case mute_level
          when 'hide' then @before[:read_access] && @level == 'hidden'
          when 'mask' then LEVEL.effective_level(@before) != 'masked' && @level == 'masked'
          when 'no_edit' then @before[:edit_access] && @level != 'hidden' && !@entry[:edit_access]
          end
        end
      end
    end
  end
end
