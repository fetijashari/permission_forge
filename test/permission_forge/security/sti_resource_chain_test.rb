require 'test_helper'
require_relative '../sti_models'

module PermissionForge
  module Security
    # Pre-release review core-security #3: an STI subclass of a protected model
    # looked its Resource up by its own name, which has no row, so every row
    # rule of its parent vanished (find_by, permission_scoped, the auto scope,
    # associations) and its fields were unconfigured. A class now answers to
    # its own Resource entry and to every ancestor's up to base_class — one
    # resolver, PermissionForge::ResourceChain, for every path.
    class StiResourceChainTest < ActiveSupport::TestCase
      NotAuthorized = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

      setup do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        @user = create_user
        @other = create_user
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @base = create_resource(permission_set: @set, name: 'PfStiTicket', read_access: true, edit_access: true)
        create_resource_field(resource: @base, name: 'title', label: 'Title', read_access: true, edit_access: true)
        create_resource_field(resource: @base, name: 'email', label: 'Email', read_access: true, mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: @base, name: 'secret', label: 'Secret', read_access: false)
        create_permission_set_rule(permission_set: @set, resource: @base, name: 'Own tickets', field_name: 'owner_id',
                                   operator: 'equal', field_value: 'current_user', include_nulls: false)

        @mine = PfStiBugTicket.create!(title: 'Mine', email: 'me@acme.com', secret: 's1', status: 'open', owner: @user)
        @theirs = PfStiBugTicket.create!(title: 'Theirs', email: 'them@acme.com', secret: 's2', status: 'open', owner: @other)
        @mine_closed = PfStiBugTicket.create!(title: 'Closed', email: 'me@acme.com', secret: 's3', status: 'closed', owner: @user)
        @urgent_theirs = PfStiUrgentBugTicket.create!(title: 'Urgent', secret: 's4', status: 'open', owner: @other)
        @user.regenerate_permissions
        Current.user = @user
      end

      teardown do
        PermissionForge.configuration.auto_query_scoping = :off
      end

      # A Resource row for the subclass in the user's set.
      def subclass_resource(**attrs)
        resource = create_resource(permission_set: @set, name: 'PfStiBugTicket', read_access: true, edit_access: true, **attrs)
        @user.regenerate_permissions
        resource
      end

      def status_rule(resource)
        create_permission_set_rule(permission_set: @set, resource: resource, name: 'Open only', field_name: 'status',
                                   operator: 'equal', field_value: 'open', include_nulls: false)
        @user.regenerate_permissions
      end

      def denied?(klass, record)
        klass.find_by(id: record.id)
        false
      rescue NotAuthorized
        true
      end

      # --- a subclass without a Resource of its own -----------------------------------

      test 'find_by and find_by! on a subclass obey the base rules' do
        assert_equal @mine, PfStiBugTicket.find_by(id: @mine.id)
        assert denied?(PfStiBugTicket, @theirs)
        assert denied?(PfStiUrgentBugTicket, @urgent_theirs)
        assert denied?(PfStiTicket, @theirs), 'the base, as before'
        assert_raises(NotAuthorized) { PfStiBugTicket.find_by!(id: @theirs.id) }
        assert_raises(ActiveRecord::RecordNotFound) { PfStiBugTicket.find_by!(id: 0) }
        assert_nil PfStiBugTicket.find_by(id: 0)
      end

      test 'permission_scoped and the auto scope on a subclass apply the base rules' do
        assert_equal %w[Closed Mine], PfStiBugTicket.permission_scoped.order(:title).pluck(:title)
        assert_empty PfStiUrgentBugTicket.permission_scoped
        assert_equal %w[Closed Mine], PfStiTicket.permission_scoped.order(:title).pluck(:title)

        PermissionForge.configuration.auto_query_scoping = :filter_only
        assert_equal %w[Closed Mine], PfStiBugTicket.all.order(:title).pluck(:title)
        assert_equal %w[Closed Mine], PfStiBugTicket.where(status: %w[open closed]).order(:title).pluck(:title)
        assert_equal 0, PfStiUrgentBugTicket.count
        assert_raises(ActiveRecord::RecordNotFound) { PfStiBugTicket.find(@theirs.id) }
      end

      test 'a subclass instance masks and hides fields like the base, on every read path' do
        theirs = PermissionForge.without_permission_scope { PfStiBugTicket.find(@theirs.id) }

        assert_equal 'Theirs', theirs.title
        assert_equal 't***@acme.com', theirs.email
        assert_nil theirs.secret
        assert_nil theirs[:secret]
        json = theirs.as_json
        assert_equal ['Theirs', 't***@acme.com'], json.values_at('title', 'email')
        assert_not json.key?('secret')
        assert_equal({ title: 'T', email: 't***@acme.com' },
                     PermissionForge::Services::FiltersResponseAttributes.call(
                       attributes: { title: 'T', email: 'them@acme.com', secret: 's' }, resource_name: 'PfStiBugTicket', user: @user
                     ))
        assert_equal({ 'title' => 'x' },
                     PermissionForge::Services::PermitsAttributes.call(resource: PfStiBugTicket,
                                                                       permitted_params: { 'title' => 'x', 'email' => 'e', 'secret' => 's' }))
        assert_equal %i[PfStiBugTicket PfStiTicket], PermissionForge::Concerns::MaskedAttributes.explain(theirs, :secret)[:resource_chain]
        rows = nil
        capture_io { rows = PermissionForge::Concerns::MaskedAttributes.explain_all(theirs) } # it also prints a table
        assert_equal :hidden_no_read_access, rows.find { |row| row[:attribute] == 'secret' }[:decision]
      end

      test 'a grandchild answers to all three names' do
        urgent = PermissionForge.without_permission_scope { PfStiUrgentBugTicket.find(@urgent_theirs.id) }

        assert_nil urgent.secret
        assert_equal %i[PfStiUrgentBugTicket PfStiBugTicket PfStiTicket], PermissionForge::ResourceChain.names(PfStiUrgentBugTicket)
      end

      # --- a subclass with a Resource of its own ---------------------------------------

      test 'the rules of the subclass entry and of the base entry apply together' do
        status_rule(subclass_resource)

        assert_equal @mine, PfStiBugTicket.find_by(id: @mine.id)
        assert denied?(PfStiBugTicket, @mine_closed), 'the subclass rule'
        assert denied?(PfStiBugTicket, @theirs), 'the base rule'
        assert_equal %w[Mine], PfStiBugTicket.permission_scoped.pluck(:title)
        assert_equal %w[Closed Mine], PfStiTicket.permission_scoped.order(:title).pluck(:title), 'the base is not held to the subclass rule'
        assert_empty PfStiUrgentBugTicket.permission_scoped, 'the grandchild is held to both'
      end

      test 'view_all on the subclass entry skips its own rules, not the base rules' do
        status_rule(subclass_resource(view_all: true))

        assert_equal @mine_closed, PfStiBugTicket.find_by(id: @mine_closed.id)
        assert denied?(PfStiBugTicket, @theirs)
        assert_equal %w[Closed Mine], PfStiBugTicket.permission_scoped.order(:title).pluck(:title)
      end

      test 'view_all on the base entry skips the base rules, not the subclass rules' do
        status_rule(subclass_resource)
        @base.update!(view_all: true)
        @user.regenerate_permissions

        assert_equal @theirs, PfStiBugTicket.find_by(id: @theirs.id)
        assert denied?(PfStiBugTicket, @mine_closed)
        assert_equal %w[Mine Theirs Urgent], PfStiBugTicket.permission_scoped.order(:title).pluck(:title),
                     'the open ones, the grandchild row included (it is a bug ticket too)'
        assert_equal 4, PfStiTicket.permission_scoped.count, 'the base itself is bypassed'
      end

      test 'a field is as closed as the strictest entry along the chain' do
        resource = subclass_resource
        create_resource_field(resource: resource, name: 'secret', label: 'Secret', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'email', label: 'Email', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'title', label: 'Title', read_access: true, edit_access: false)
        create_resource_field(resource: resource, name: 'status', label: 'Status', read_access: true, edit_access: true)
        @user.regenerate_permissions
        mine = PermissionForge.without_permission_scope { PfStiBugTicket.find(@mine.id) }

        assert_nil mine.secret, 'hidden in the base stays hidden'
        assert_equal 'm***@acme.com', mine.email, 'masked in the base stays masked'
        assert_equal 'open', mine.status, 'configured by the subclass alone'
        assert_equal({ 'status' => 'closed' },
                     PermissionForge::Services::PermitsAttributes.call(
                       resource: mine, permitted_params: { 'title' => 'x', 'email' => 'e', 'secret' => 's', 'status' => 'closed' }
                     ), 'edit needs every configuring entry')
        plain = PfStiTicket.create!(title: 'Plain', status: 'open', owner: @user)
        assert_nil PermissionForge.without_permission_scope { PfStiTicket.find(plain.id) }.status,
                   'a record of the base is not opened by the subclass entry'
        assert_kind_of PfStiBugTicket, PermissionForge.without_permission_scope { PfStiTicket.find(@mine.id) },
                       'a row of the subclass is one through the base too'
      end

      # --- a subclass with a table of its own (review MAJOR-3) ---------------------------

      test 'a subclass with a table of its own is not held to the base rules, which name a column it lacks' do
        archived = PfStiArchivedTicket.create!(title: 'arch', owner: @other)

        assert_equal archived, PfStiArchivedTicket.find_by(id: archived.id)
        assert_equal %w[arch], PfStiArchivedTicket.permission_scoped.pluck(:title)
        PermissionForge.configuration.auto_query_scoping = :filter_only
        assert_equal %w[arch], PfStiArchivedTicket.all.pluck(:title)
      end

      # --- muted read along the chain (review MINOR-3) -----------------------------------

      test 'muting the base read hides the fields only the subclass entry configures' do
        resource = subclass_resource
        create_resource_field(resource: resource, name: 'email', label: 'Email', read_access: true)
        create_resource_field(resource: resource, name: 'status', label: 'Status', read_access: true, edit_access: true)
        muting = create_permission_set(name: 'Offboarding', is_muting: true)
        create_permission_set_user(user: @user, permission_set: muting)
        create_resource(permission_set: muting, name: 'PfStiTicket', read_access: true)
        @user.regenerate_permissions
        mine = PermissionForge.without_permission_scope { PfStiBugTicket.find(@mine.id) }

        assert_not @user.can_read?(:PfStiTicket)
        assert_not @user.can_read?(:PfStiBugTicket), 'the muted base reaches the subclass entry, whose flags can_*? reads'
        assert_nil mine.email
        assert_nil mine.status, 'configured by the subclass alone, hidden all the same'
        assert_nil mine.title
        assert_empty PermissionForge::Services::FiltersResponseAttributes.call(
          attributes: { status: 'open', title: 'T' }, resource_name: 'PfStiBugTicket', user: @user
        )
        assert_empty PermissionForge::Services::PermitsAttributes.call(resource: PfStiBugTicket,
                                                                       permitted_params: { 'status' => 'closed', 'title' => 'x' })
      end

      # --- nothing along the chain ------------------------------------------------------

      test 'without an entry anywhere along the chain a subclass is unconfigured, as the base would be' do
        stranger = create_user
        other_set = create_permission_set
        create_permission_set_user(user: stranger, permission_set: other_set)
        create_resource(permission_set: other_set, name: 'Customer')
        Current.user = stranger
        theirs = PfStiBugTicket.find_by(id: @theirs.id)

        assert_equal @theirs, theirs, 'no rules means no restriction'
        assert_nil theirs.title, 'blocked under unconfigured_field_strategy = :block'
      end
    end
  end
end
