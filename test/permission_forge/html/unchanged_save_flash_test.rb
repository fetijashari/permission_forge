require_relative 'admin_test_case'
require_relative 'rendered_forms'
require_relative '../../support/static_guard'

module PermissionForge
  module Html
    # Field test round 8 (B#70): submits that changed nothing said different
    # things — the field drawer and the set page "No changes to save.", the
    # group "Group saved. No one's access changed.", the action form
    # "Saved “Export”. It applies immediately.", the rule builder "Saved the
    # rule “Own customers”." — although none saved anything (no row changed,
    # no audit event written).
    #
    # One definition (SaveNotice): a save that changed nothing an audit
    # event records (RecordsAuditEvents#saved_audited_changes?), or a batched
    # edit with no change (Admin::ChangeSet), says "No changes to save.".
    # Every admin form that saves a record is submitted here as the page
    # renders it, with nothing changed.
    class UnchangedSaveFlashTest < AdminTestCase
      include RenderedForms

      # Templates holding a PATCH form, and what they save: SAVE_FORMS are
      # walked below; the others change something by design whatever is
      # posted (a toggle, a switch, an extension, a confirmation) or save no
      # record. A new PATCH form fails the inventory test until it is
      # classified.
      SAVE_FORMS = {
        'resource_fields/show' => 'the field drawer',
        'resource_actions/show' => 'the action form',
        'permission_set_rules/edit' => 'the rule builder',
        'permission_set_groups/show' => 'the group page',
        'permission_sets/_conditions_tab' => 'the Conditions tab',
        'people/_access_tab' => "a person's end-date select",
        'permission_sets/_assignments_tab' => "the Assignments tab's end-date select",
        'permission_sets/review' => 'the set page (Review, then apply)'
      }.freeze
      NOT_SAVE_FORMS = {
        'home/_ending_card' => 'Extend 30 days: always moves the end date',
        'permission_sets/confirm_switch_mode' => 'switches granting/muting: always a change',
        'resources/_rules_tab' => 'turns a rule on or off: always a change',
        'shared/_preferences' => 'a cookie (theme), no record',
        'shared/_help_banner' => 'a cookie (dismissed help), no record'
      }.freeze

      setup do
        @action = create_resource_action(resource: @resource, name: 'export', label: 'Export')
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own customers',
                                           field_name: 'domain', field_value: 'acme.test', include_nulls: false)
        @group = create_permission_set_group(name: 'Sales', description: 'Front line')
        @set.update!(allowed_ips: '10.0.0.0/8', requires_session_flag: 'mfa', permission_set_group: @group)
      end

      # Ana holds @set: her cached permissions, built and stored.
      def warm_holder_cache
        PermissionForge.cache.clear
        User.find(@ana.id).permissions_hash
        assert holder_cached?, 'the holder has a cached entry'
      end

      def holder_cached? = PermissionForge.cache.read(@ana.send(:permission_cache_key)).present?

      # [what it said, the events it wrote, whether the holder's entry was kept] of the block's submit.
      def submit_outcome
        warm_holder_cache
        before = AuditEvent.unscoped.pluck(:id)
        yield
        [[flash[:notice], flash[:alert]].compact, AuditEvent.unscoped.where.not(id: before).pluck(:event), holder_cached?]
      end

      def base = "/permission_sets/#{@set.id}"
      def resource_base = "#{base}/resources/Customer"

      # [label, page, form action, options] of every admin form that saves a
      # record, submitted unchanged: `to:` sends the review form straight to
      # apply (the review page's own form posts the same parameters).
      def unchanged_submits # rubocop:disable Metrics/AbcSize -- one row per form
        [
          ['field drawer', "#{resource_base}/fields/email", "#{resource_base}/fields/email"],
          # Its "Apply recommendation" button (formaction), from a page opened before the mask was applied.
          ['field drawer: apply recommendation', "#{resource_base}/fields/email", "#{resource_base}/fields/email",
           { to: "#{resource_base}/fields/email/apply_recommendation", '_method' => 'post' }],
          ['action form', "#{resource_base}/actions/#{@action.id}", "#{resource_base}/actions/#{@action.id}"],
          ['rule builder', "#{resource_base}/rules/#{@rule.id}/edit", "#{resource_base}/rules/#{@rule.id}"],
          ['group page', "/groups/#{@group.id}", "/groups/#{@group.id}"],
          ['Conditions tab', "#{base}?tab=conditions", "#{base}/conditions"],
          ['set page: review', base, "#{base}/review"],
          ['set page: apply', base, "#{base}/review", { to: "#{base}/apply", '_method' => 'patch' }],
          ['Resource page: review', resource_base, "#{resource_base}/review"],
          ['Resource page: apply', resource_base, "#{resource_base}/review", { to: "#{resource_base}/apply", '_method' => 'patch' }],
          ["person's end date, nothing chosen", "/people/#{@ana.id}", "/assignments/#{@assignment.id}"],
          ["person's end date, the one it has", "/people/#{@ana.id}", "/assignments/#{@assignment.id}", { 'expiry' => 'never' }],
          ['Assignments tab end date, nothing chosen', "#{base}?tab=assignments", "/assignments/#{@assignment.id}"]
        ]
      end

      # Review of the round-8 fix: an unchanged record was still saved, and
      # Rails runs the commit callbacks of a save that wrote nothing — every
      # holder's cached permissions were invalidated (InvalidatesInBatch,
      # PermissionSetUser). An unchanged record is not saved now
      # (SaveNotice#pf_save_changed).
      test 'every admin form that saves a record, submitted unchanged, says No changes to save, writes no event, keeps the cache' do
        no_changes = I18n.t('permission_forge.flash.no_changes')
        failures = unchanged_submits.filter_map do |label, page, action, options|
          said, events, kept = submit_outcome { submit_as_rendered(page, action, **(options || {})) }
          next if said == [no_changes] && events.empty? && kept

          "#{label}: said #{said.inspect}, wrote #{events.inspect}, #{kept ? 'kept' : 'invalidated'} the holder's cache"
        end

        assert_empty failures, failures.join("\n")
      end

      def saved_text(count = 1) = I18n.t('permission_forge.flash.permission_sets.saved', count: count, people: '1 person')

      # [label, the submit, the flash it starts with, the one event it writes] of
      # every walked form, each with a change (the review steps save nothing).
      def changed_submits # rubocop:disable Metrics/AbcSize,Metrics/MethodLength -- one row per form
        field = "#{resource_base}/fields/email"
        action = "#{resource_base}/actions/#{@action.id}"
        rule = "#{resource_base}/rules/#{@rule.id}"
        [
          ['field drawer', -> { submit_as_rendered(field, field, 'field[level]' => 'read') }, saved_text, 'resource_field.updated'],
          ['field drawer: apply recommendation', lambda {
            @email.update_columns(mask_access: false) # no event of its own
            submit_as_rendered(field, field, to: "#{field}/apply_recommendation", '_method' => 'post')
          }, I18n.t('permission_forge.flash.fields.recommendation_applied', field: 'email'), 'resource_field.updated'],
          ['action form', -> { submit_as_rendered(action, action, 'resource_action[label]' => 'Export CSV') },
           I18n.t('permission_forge.flash.actions.updated', action: 'Export CSV'), 'resource_action.updated'],
          ['rule builder', -> { submit_as_rendered("#{rule}/edit", rule, 'rule[value]' => 'other.test') },
           I18n.t('permission_forge.flash.rules.updated', rule: 'Own customers'), 'permission_set_rule.updated'],
          ['group page', -> { submit_as_rendered("/groups/#{@group.id}", "/groups/#{@group.id}", 'group[description]' => 'Back office') },
           I18n.t('permission_forge.flash.groups.updated'), 'permission_set_group.updated'],
          ['Conditions tab', -> { submit_as_rendered("#{base}?tab=conditions", "#{base}/conditions", 'allowed_ips' => '10.0.0.0/8 192.168.0.0/16') },
           I18n.t('permission_forge.flash.permission_sets.conditions_saved'), 'permission_set.updated'],
          ['set page: apply', lambda {
            submit_as_rendered(base, "#{base}/review", to: "#{base}/apply", '_method' => 'patch', 'pf[set][description]' => 'New desc')
          }, saved_text, 'permission_set.updated'],
          ['Resource page: apply', lambda {
            submit_as_rendered(resource_base, "#{resource_base}/review", to: "#{resource_base}/apply", '_method' => 'patch',
                                                                         "pf[resources][#{@resource.id}][delete_access]" => '1')
          }, saved_text, 'resource.updated'],
          ["person's end date", -> { submit_as_rendered("/people/#{@ana.id}", "/assignments/#{@assignment.id}", 'expiry' => '30d') },
           "Ana Krasniqi's access to Sales rep", 'assignment.changed'],
          ['Assignments tab end date', -> { submit_as_rendered("#{base}?tab=assignments", "/assignments/#{@assignment.id}", 'expiry' => '1w') },
           "Ana Krasniqi's access to Sales rep", 'assignment.changed']
        ]
      end

      test 'every walked form submitted with a change says what it saved, writes one event, invalidates the holder' do
        failures = changed_submits.filter_map do |label, submit, said_start, event|
          said, events, kept = submit_outcome(&submit)
          next if said.size == 1 && said.first.start_with?(said_start) && events == [event] && !kept

          "#{label}: said #{said.inspect}, wrote #{events.inspect}, #{kept ? 'kept' : 'invalidated'} the holder's cache"
        end

        assert_empty failures, failures.join("\n")
      end

      # Review of the round-8 fix: a batched edit sent straight to apply
      # whose every change is refused (Edit with Read off) says why, as the
      # review step does — not a bare "No changes to save.".
      test 'an apply whose every change was refused says why, as the review does' do
        @resource.update!(read_access: false, edit_access: false)
        params = { pf: { resources: { @resource.id => { read_access: '0', edit_access: '1' } } }, locale: 'en' }
        reason = I18n.t('permission_forge.ui.changes.not_applied_read', resource: 'Customer',
                                                                        flag: I18n.t('permission_forge.ui.flags_short.edit_access'))

        %W[#{resource_base}/apply #{base}/apply].each do |path|
          patch pf(path), params: params
          assert_equal I18n.t('permission_forge.flash.permission_sets.nothing_applied', reasons: reason), flash[:alert], path
          assert_nil flash[:notice], path
        end
        assert_not @resource.reload.edit_access
      end

      # Whether a save changes something is decided by RecordsAuditEvents
      # (#audited_changes_pending? before, #saved_audited_changes? after,
      # through SaveNotice); an admin controller reading dirty tracking
      # itself would decide it a second way.
      DIRTY_READS = /(?:\b|_)(?:changed\?|saved_change_to_\w+|will_save_change_to_\w+)/
      DIRTY_READ_ALLOWED = [
        ['app/controllers/permission_forge/settings_controller.rb', /row\.changed\?/,
         'a Settings row differs from the default (Admin::SettingsCatalog), no record'],
        ['app/controllers/permission_forge/api/permission_sets_controller.rb', /permission_set_group_id_changed\?/,
         'the lock check of a group move (EditableLock.locked_group_for_move) before the save, not its outcome']
      ].freeze

      test 'no admin controller decides by itself whether a save changes something' do
        scope = { globs: %w[app/controllers/**/*.rb], needle: DIRTY_READS }
        hits = StaticGuard.scan(**scope, allowlist: DIRTY_READ_ALLOWED)

        assert_empty hits.map(&:to_s)
        StaticGuard.assert_allowlist_current(self, **scope, allowlist: DIRTY_READ_ALLOWED)
        assert_match DIRTY_READS, StaticGuard.code_of('return unless @rule.changed?'), 'the needle bites a bare changed?'
        assert_match DIRTY_READS, StaticGuard.code_of('flash = saved_change_to_label? ? a : b'), 'and saved_change_to_*'
      end

      test 'every template with a PATCH form is classified: walked as a save, or why it is not one' do
        templates = Dir[File.expand_path('../../../app/views/permission_forge/**/*.erb', __dir__)].select do |file|
          File.read(file).match?(/method: :patch/)
        end
        names = templates.map { |file| file[%r{app/views/permission_forge/(.+)\.html\.erb\z}, 1] }

        assert_equal (SAVE_FORMS.keys + NOT_SAVE_FORMS.keys).sort, names.sort
      end
    end
  end
end
