# frozen_string_literal: true

require_relative 'integration_support'

module PermissionForge
  module AuditIntegration
    # Runtime decisions through real host requests (the dummy app's
    # CustomersController with the action guard, and PfAuditProbesController
    # reading and writing Customer): each is published, stored only when its
    # group is in config.audit_runtime_events (denials by default), with the
    # user, the model and the record — never a value.
    class RuntimeEventsTest < ActionDispatch::IntegrationTest
      include IntegrationSupport

      PROBE = '/pf_audit_probe/customers'

      setup do
        @user = create_user(name: 'Grace Hopper')
        @set = create_permission_set(name: 'Support')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_permission_set_user(user: @user, permission_set: @set)
        @mine = create_customer(name: 'Mine', supplier_id: @user.id, email: 'mine@example.com')
        @theirs = create_customer(name: 'Theirs', supplier_id: @user.id + 1000)
        sign_in(@user)
      end

      teardown do
        PermissionForge.configuration.auto_query_scoping = :off
      end

      test 'a controller action the user may not run is action.denied, stored by default' do
        create_resource_action(resource: @resource, name: 'archive', is_permitted: false)

        published = notifications('action.denied') { post "/customers/#{@mine.id}/archive" }

        assert_response :forbidden
        assert_equal 1, published.size
        assert_runtime_event('action.denied', record_type: 'Customer', data: { 'reason' => 'action_denied', 'action' => 'archive',
                                                                               'controller' => 'customers', 'via' => 'action_guard' })
      end

      test 'action.denied is published but not stored when the denied group is off' do
        create_resource_action(resource: @resource, name: 'archive', is_permitted: false)
        PermissionForge.configuration.audit_runtime_events = []

        stored = events_during { assert_equal 1, notifications('action.denied') { post "/customers/#{@mine.id}/archive" }.size }

        assert_response :forbidden
        assert_empty stored
      end

      test 'a row the record rules deny through find_by is access.denied with its id; an allowed row is not' do
        create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own customers', include_nulls: false)

        allowed = events_during { get "#{PROBE}/#{@mine.id}" }
        assert_response :ok
        assert_empty allowed.map(&:event)

        get "#{PROBE}/#{@theirs.id}"
        assert_response :forbidden
        assert_runtime_event('access.denied', record_type: 'Customer', record_id: @theirs.id.to_s,
                                              data: { 'reason' => 'rule', 'via' => 'find_by' })
      end

      test 'a bypass under auto-scoping is published once per request, stored only with the bypass group' do
        PermissionForge.configuration.auto_query_scoping = :filter_only
        @resource.update!(view_all: true)

        not_stored = events_during do
          assert_equal 1, notifications('rule.bypassed') { get PROBE }.size, 'two queries, one event per request'
        end
        assert_response :ok
        assert_empty not_stored

        PermissionForge.configuration.audit_runtime_events = %i[denied bypass]
        stored = events_during { 2.times { get PROBE } }
        assert_equal [%w[view_all auto_scope]] * 2, stored.map { |event| event.data.values_at('reason', 'via') }, 'one per request'
        assert_runtime_event('rule.bypassed', record_type: 'Customer', data: { 'model' => 'Customer' })
      end

      test 'a record read is one field.access event naming the masked and hidden fields, without values, when field_read is stored' do
        create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: @resource, name: 'domain', read_access: false)

        assert_empty(events_during { get "#{PROBE}/#{@mine.id}" }, 'field_read is not stored by default')

        PermissionForge.configuration.audit_runtime_events = %i[denied field_read]
        events = events_during { get "#{PROBE}/#{@mine.id}" }

        assert_response :ok
        assert_not_includes response.body, 'mine@example.com'
        assert_equal ['field.access'], events.map(&:event)
        event = assert_runtime_event('field.access', record_type: 'Customer', record_id: @mine.id.to_s)
        assert_equal [['email'], ['domain']], event.data.values_at('masked', 'hidden')
        assert_no_values(event, 'mine@example.com', 'example.com')
      end

      test 'dropped parameters are params.filtered with their names only, when params_filtered is stored' do
        create_resource_field(resource: @resource, name: 'name', read_access: true, edit_access: true)
        create_resource_field(resource: @resource, name: 'email', read_access: true, edit_access: false)
        params = { customer: { name: 'New name', email: 'evil@example.com' } }

        assert_empty(events_during { patch "#{PROBE}/#{@mine.id}", params: params }, 'params_filtered is not stored by default')

        PermissionForge.configuration.audit_runtime_events = %i[denied params_filtered]
        patch "#{PROBE}/#{@mine.id}", params: params

        assert_equal({ 'name' => 'New name' }, response.parsed_body)
        event = assert_runtime_event('params.filtered', data: { 'reason' => 'field_access', 'dropped' => ['email'] })
        assert_no_values(event, 'evil@example.com', 'New name')
      end

      private

      def notifications(event)
        seen = []
        subscriber = ActiveSupport::Notifications.subscribe("#{event}.permission_forge") { |*, payload| seen << payload }
        yield
        seen
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # The event, stored with the request's user as actor and subject, source runtime.
      def assert_runtime_event(name, **attrs)
        assert_audit_event(name, category: 'access', source: 'runtime', actor_type: 'user', actor_id: @user.id.to_s,
                                 actor_label: 'Grace Hopper', subject_user_id: @user.id.to_s, **attrs)
      end

      def assert_no_values(event, *values)
        stored = event.attributes.to_json
        values.each { |value| assert_not_includes stored, value, "#{event.event} stores no value" }
      end
    end
  end
end
