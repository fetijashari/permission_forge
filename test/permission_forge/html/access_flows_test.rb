require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Giving and taking access: assignments, bulk assign/revoke, person actions.
    class AccessFlowsTest < AdminTestCase
      test 'assigning a set with an end date, then undo' do
        other = create_permission_set(name: 'Support')

        post pf('/assignments'), params: { user_id: @bo.id, set_ids: [other.id], expiry: '1w' }

        a = PermissionForge::PermissionSetUser.find_by(user: @bo, permission_set: other)
        assert_equal Time.zone.today + 7, a.expires_at.to_date
        assert_redirected_to pf("/people/#{@bo.id}")
        assert_equal 'post', flash[:pf_undo][:method]

        post pf('/assignments/undo'), params: { ids: [a.id] }
        assert_not PermissionForge::PermissionSetUser.exists?(a.id)
      end

      test 'assign validation names what is missing' do
        post pf('/assignments'), params: { expiry: 'custom', custom_date: '' }

        assert_response :unprocessable_entity
        assert_match I18n.t('permission_forge.errors.admin.person'), response.body
        assert_match I18n.t('permission_forge.errors.admin.sets'), response.body
      end

      test 'locked sets cannot be assigned through the form' do
        locked = create_permission_set(name: 'System', is_editable: false)

        post pf('/assignments'), params: { user_id: @bo.id, set_ids: [locked.id] }

        assert_response :unprocessable_entity
        assert_not PermissionForge::PermissionSetUser.exists?(user: @bo, permission_set: locked)
      end

      test 'change end date, extend and keep' do
        patch pf("/assignments/#{@assignment.id}"), params: { expiry: 'eom' }
        assert_equal Time.zone.today.end_of_month, @assignment.reload.expires_at.to_date

        patch pf("/assignments/#{@assignment.id}"), params: { expiry: 'extend30' }
        assert_equal Time.zone.today.end_of_month + 30, @assignment.reload.expires_at.to_date

        @assignment.update_columns(created_at: 200.days.ago)
        post pf("/assignments/#{@assignment.id}/keep")
        assert @assignment.reload.reviewed_at > 1.minute.ago
      end

      test 'remove, then restore with undo' do
        @assignment.update!(expires_at: 5.days.from_now.end_of_day)
        delete pf("/assignments/#{@assignment.id}")
        assert_not PermissionForge::PermissionSetUser.exists?(@assignment.id)

        undo = flash[:pf_undo]
        post undo[:path], params: undo[:params]
        restored = PermissionForge::PermissionSetUser.find_by(user: @ana, permission_set: @set)
        assert_equal (Time.zone.today + 5), restored.expires_at.to_date
      end

      # The toast's Undo posts the end date the admin itself wrote
      # (TimeWithZone#iso8601(6), with the zone's offset): each preset and a
      # custom date come back exactly (23:59:59.999999), also outside UTC.
      test 'every end date the assign form sets survives remove and the toast undo' do
        previous = Time.zone_default
        # use_zone first: it restores the zone it read on entry.
        Time.use_zone('Europe/Berlin') do
          Time.zone_default = ActiveSupport::TimeZone['Europe/Berlin']
          custom = (Time.zone.today + 12).iso8601
          { '1d' => nil, '1w' => nil, '30d' => nil, 'eom' => nil, 'custom' => custom }.each do |expiry, custom_date|
            assert_undo_restores_end_date(expiry, custom_date)
          end
        ensure
          Time.zone_default = previous
        end
      end

      test 'bulk assign from pasted emails and bulk revoke' do
        post pf("/permission_sets/#{@set.id}/bulk_assignment/preview"), params: { identifiers: "bo@acme.test\nghost@x.test" }
        assert_match 'ghost@x.test', response.body

        post pf("/permission_sets/#{@set.id}/bulk_assignment"), params: { identifiers: 'bo@acme.test', expiry: 'never' }
        assert PermissionForge::PermissionSetUser.exists?(user: @bo, permission_set: @set)

        delete pf("/permission_sets/#{@set.id}/bulk_assignment/revoke"), params: { user_ids: [@ana.id, @bo.id] }
        assert_equal 0, @set.permission_set_users.count
      end

      test 'bulk assign with nobody found is refused' do
        post pf("/permission_sets/#{@set.id}/bulk_assignment"), params: { identifiers: 'nobody@x.test' }

        assert_response :unprocessable_entity
      end

      test 'remove all access, withdraw consent and refresh cache' do
        gated = create_permission_set(name: 'Marketing', requires_session_flag: 'marketing_consent')
        create_permission_set_user(user: @ana, permission_set: gated)

        get pf("/people/#{@ana.id}/consent"), params: { flag: 'marketing_consent' }
        assert_match 'Marketing', response.body
        post pf("/people/#{@ana.id}/consent"), params: { flag: 'marketing_consent' }
        assert_not PermissionForge::PermissionSetUser.exists?(user: @ana, permission_set: gated)

        post pf("/people/#{@ana.id}/refresh_cache")
        assert_redirected_to pf("/people/#{@ana.id}")

        delete pf("/people/#{@ana.id}/remove_all")
        assert_equal 0, PermissionForge::PermissionSetUser.where(user: @ana).count
      end

      test 'erasure requires typing the exact name' do
        post pf("/people/#{@ana.id}/erasure"), params: { confirmation: 'ana' }
        assert_response :unprocessable_entity
        assert PermissionForge::PermissionSetUser.exists?(@assignment.id)

        post pf("/people/#{@ana.id}/erasure"), params: { confirmation: 'Ana Krasniqi' }
        assert_redirected_to pf('/people')
        assert_not PermissionForge::PermissionSetUser.exists?(@assignment.id)
      end

      test 'person audit exports CSV' do
        get pf("/people/#{@ana.id}"), params: { tab: 'audit', format: 'csv' }

        assert_equal 'text/csv', response.media_type
        assert response.body.start_with?('Type,Record,Where')
      end

      test 'clean up expired assignments from home' do
        @assignment.update_columns(expires_at: 2.days.ago)

        delete pf('/maintenance/cleanup')

        assert_not PermissionForge::PermissionSetUser.exists?(@assignment.id)
      end

      test 'unknown people are not found' do
        get pf('/people/0')

        assert_response :not_found
      rescue ActionController::RoutingError
        pass
      end

      private

      # Assign with the preset, remove, then submit the Undo form the toast
      # renders (its hidden fields, as a browser would).
      def assert_undo_restores_end_date(expiry, custom_date)
        assignment = assign_with_end_date(expiry, custom_date)
        ends = assignment.expires_at
        action, fields = remove_and_read_undo(assignment)
        assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}[+-]\d{2}:\d{2}\z/, fields['expires_at'],
                     'written with microseconds and the zone offset')

        post action, params: fields
        restored = PermissionForge::PermissionSetUser.find_by!(user: @bo, permission_set: assignment.permission_set_id)
        assert_equal ends, restored.expires_at, "#{expiry}: #{fields['expires_at']}"
      end

      def remove_and_read_undo(assignment)
        delete pf("/assignments/#{assignment.id}")
        follow_redirect!
        undo_form
      end

      def assign_with_end_date(expiry, custom_date)
        set = create_permission_set(name: "Ends #{expiry}")
        post pf('/assignments'), params: { user_id: @bo.id, set_ids: [set.id], expiry: expiry, custom_date: custom_date }
        assignment = PermissionForge::PermissionSetUser.find_by!(user: @bo, permission_set: set)
        expected = PermissionForge::Admin::ExpiryPresets.expires_at_for(expiry, custom: custom_date)
        assert_equal expected.to_i, assignment.expires_at.to_i
        assignment
      end

      # The toast's Undo form: [action, { name => value }].
      def undo_form
        form = css_select('.pf-toast form').first
        assert form, 'no Undo form in the toast'
        [form['action'], css_select(form, 'input[type=hidden]').to_h { |input| [input['name'], input['value']] }]
      end
    end
  end
end
