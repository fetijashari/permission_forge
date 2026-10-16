require 'test_helper'

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
        'muted: no edit' => [[:grant, 'edit'], [:mute, :no_edit]],
        'muted: no edit on a read-only field' => [[:grant, 'read'], [:mute, :no_edit]],
        'muted: the resource read' => [[:grant, 'edit'], [:mute, nil, { resource: { read_access: true } }]],
        'muted: the resource edit' => [[:grant, 'edit'], [:mute, nil, { resource: { edit_access: true } }]],
        'muted: mask on a field nobody shows' => [[:grant, 'hidden'], [:mute, 'mask']],
        'muted: hide on a field nobody shows' => [[:grant, 'hidden'], [:mute, 'hide']],
        'muted: mask, then hide' => [[:grant, 'edit'], [:mute, 'mask'], [:mute, 'hide']],
        'muted: no edit, then mask' => [[:grant, 'edit'], [:mute, :no_edit], [:mute, 'mask']],
        'not configured' => [[:grant, nil]]
      }.freeze

      # What a mute that decides makes of the entry.
      MUTE_LEVELS = { 'hide' => 'hidden', 'mask' => 'masked', 'no_edit' => 'read' }.freeze

      test 'every WHY level word equals the level the hash entry gives, for every state' do
        failures = WHY_STATES.flat_map do |state, rows|
          user = create_user
          sets = rows.each_with_index.map { |row, index| why_set(state, index, *row) }
          sets.each { |set| create_permission_set_user(user: user, permission_set: set) }
          why_failures(state, user, sets)
        end

        assert_empty failures, failures.join("\n")
      end

      private

      def why_set(state, index, kind, level, options = {})
        set = create_permission_set(name: "#{state} #{index}", is_muting: kind == :mute, created_at: (10 - index).minutes.ago)
        resource = create_resource(permission_set: set, name: 'Customer', read_access: kind == :grant, edit_access: kind == :grant,
                                   **options.fetch(:resource, {}))
        flags = why_flags(kind, level)
        create_resource_field(resource: resource, name: 'email', mask_strategy: options.fetch(:strategy, 'full'), **flags) if flags
        set
      end

      def why_flags(kind, level)
        return if level.nil?
        return { read_access: false, edit_access: true, mask_access: false } if level == :no_edit

        PermissionForge::FieldLevel.flags_for(level, muting: kind == :mute)
      end

      # The engine's resource entry for the sets, in the order a request merges them.
      def why_engine(user, sets)
        ordered = PermissionForge::PermissionSet.where(id: sets.map(&:id)).in_hash_order.to_a
        PermissionForge::Services::PermissionHashBuilder.call(user: user, permission_sets: ordered)[:resources]['Customer']
      end

      def why_failures(state, user, sets)
        engine = why_engine(user, sets)
        before = why_engine(user, sets.reject(&:is_muting))
        field = PermissionForge::Admin::EffectiveAccess.call(user: user).find { |res| res.name == 'Customer' }
                                                      .fields.find { |outcome| outcome.name == 'email' }
        entry = engine[:fields]['email']
        return (field.unconfigured ? [] : ["#{state}: configured, the engine has no entry"]) unless entry

        why_problems(field, entry, engine, before[:fields]['email']).map { |problem| "#{state}: #{problem}" }
      end

      def why_problems(field, entry, engine, before)
        level = PermissionForge::FieldLevel.effective_level(entry)
        capped = level == 'edit' && !engine[:permissions][:edit_access]
        muted = level == 'hidden' && PermissionForge::FieldLevel.effective_level(before) != 'hidden'
        problems = []
        problems << "badge #{why_badge(field)}, the entry gives #{why_word(capped ? 'read' : level, muted)}" unless
          why_badge(field) == why_word(capped ? 'read' : level, muted)
        problems << "capped #{field.capped}, expected #{capped}" unless field.capped == capped
        problems.concat(why_reason_problems(field, entry, level, before))
      end

      # The badge's words, as the panel draws them.
      def why_badge(field)
        Nokogiri::HTML.fragment(PermissionForge::ApplicationController.helpers.pf_effective_field_badge(field)).text
                      .sub(/\A\S+ /, '').sub(/ \(.*\z/, '')
      end

      def why_word(level, muted)
        return I18n.t('permission_forge.people.effective_tab.hidden_by_muting') if muted

        I18n.t("permission_forge.ui.levels.#{level}")
      end

      def why_reason_problems(field, entry, level, before)
        problems = []
        deciding = field.mutes.first
        if deciding
          problems << "the deciding mute says #{deciding.level}, the entry is #{level}" unless MUTE_LEVELS[deciding.level] == level
        elsif level == 'hidden'
          problems << "hidden by no mute, yet #{field.grants.map(&:level)} grant" if field.grants.any?
        else
          first = field.grants.first
          problems << "the deciding grant says #{first&.level.inspect}, the entry is #{level}" unless first&.level == level
          problems << "masked #{first&.mask_strategy}, the entry #{entry[:mask_strategy]}" if level == 'masked' && first &&
                                                                                                  first.mask_strategy != entry[:mask_strategy]
        end
        top = PermissionForge::FieldLevel.rank(field.grants.first&.level)
        field.grants.each { |grant| problems << "grant #{grant.level} above the deciding one" if PermissionForge::FieldLevel.rank(grant.level) > top }
        field.mutes.each { |mute| problems << "mute #{mute.level} changed nothing" unless why_mute_changed?(mute.level, entry, level, before) }
        problems << 'blocked_by is not the mutes' unless field.blocked_by == field.mutes.map(&:permission_set)
        problems
      end

      def why_mute_changed?(mute_level, entry, level, before)
        readable_before = before && before[:read_access]
        case mute_level
        when 'hide' then readable_before && level == 'hidden'
        when 'mask' then level == 'masked'
        when 'no_edit' then before && before[:edit_access] && level != 'hidden' && !entry[:edit_access]
        else false
        end
      end
    end
  end
end
