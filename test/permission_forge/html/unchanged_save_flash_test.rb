require_relative 'admin_test_case'
require_relative 'rendered_forms'

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
        @set.update!(allowed_ips: '10.0.0.0/8', requires_session_flag: 'mfa')
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

      test 'every admin form that saves a record, submitted unchanged, says No changes to save and writes no event' do
        no_changes = I18n.t('permission_forge.flash.no_changes')
        failures = unchanged_submits.filter_map do |label, page, action, options|
          before = AuditEvent.unscoped.pluck(:id)
          submit_as_rendered(page, action, **(options || {}))
          events = AuditEvent.unscoped.where.not(id: before).pluck(:event)
          said = [flash[:notice], flash[:alert]].compact
          "#{label}: said #{said.inspect}, wrote #{events.inspect}" unless said == [no_changes] && events.empty?
        end

        assert_empty failures, failures.join("\n")
      end

      test 'a save that changes something still says what it saved' do
        submit_as_rendered("#{resource_base}/actions/#{@action.id}", "#{resource_base}/actions/#{@action.id}",
                           'resource_action[label]' => 'Export CSV')
        assert_equal I18n.t('permission_forge.flash.actions.updated', action: 'Export CSV'), flash[:notice]

        submit_as_rendered("#{resource_base}/rules/#{@rule.id}/edit", "#{resource_base}/rules/#{@rule.id}", 'rule[value]' => 'other.test')
        assert_equal I18n.t('permission_forge.flash.rules.updated', rule: 'Own customers'), flash[:notice]

        submit_as_rendered("/groups/#{@group.id}", "/groups/#{@group.id}", 'group[description]' => 'Back office')
        assert_equal I18n.t('permission_forge.flash.groups.updated'), flash[:notice], 'a change that affects nobody keeps its sentence'

        submit_as_rendered("#{base}?tab=conditions", "#{base}/conditions", 'allowed_ips' => '10.0.0.0/8 192.168.0.0/16')
        assert_equal I18n.t('permission_forge.flash.permission_sets.conditions_saved'), flash[:notice]
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
