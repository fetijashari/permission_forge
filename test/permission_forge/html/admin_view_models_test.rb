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
    end
  end
end
