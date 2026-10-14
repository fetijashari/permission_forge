# frozen_string_literal: true

require_relative 'integration_support'

module PermissionForge
  module AuditIntegration
    # A change whose audit event cannot be written does not happen (under the
    # default audit_change_failure_strategy :raise) — through the admin UI,
    # the API and a service; under :report the change goes through and the
    # failure is reported.
    class AtomicityTest < ActionDispatch::IntegrationTest
      include IntegrationSupport

      setup do
        @admin = create_user(name: ADMIN_NAME)
        @ana = create_user(name: 'Ana Krasniqi')
        @set = create_permission_set(name: 'Sales rep')
        @resource = create_resource(permission_set: @set, read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email', read_access: true)
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        @assignment = create_permission_set_user(user: @ana, permission_set: @set)
        sign_in(@admin)
      end

      # --- :raise (default) -------------------------------------------------------------

      test 'admin UI: a Review-and-save whose event cannot be written saves nothing' do
        params = { pf: { set: { description: 'Edited' }, resources: { @resource.id => { create_access: '1' } } }, reason: REASON }

        failing_store(%w[resource.updated]) do
          assert_raises(Audit::EventNotRecordedError) { patch "#{ROOT}/permission_sets/#{@set.id}/apply", params: params }
        end

        assert_equal 'A test permission set', @set.reload.description, 'the earlier save of the request is rolled back too'
        assert_not @resource.reload.create_access
        assert_empty audit_events_for(@set).where(event: 'permission_set.updated')
      end

      test 'admin UI: a delete whose cascaded event cannot be written deletes nothing' do
        failing_store(%w[assignment.revoked]) do
          assert_raises(Audit::EventNotRecordedError) { delete "#{ROOT}/permission_sets/#{@set.id}" }
        end

        assert PermissionSet.exists?(@set.id)
        assert PermissionSetRule.exists?(@rule.id)
        assert PermissionSetUser.exists?(@assignment.id)
        assert_empty AuditEvent.where(event: %w[permission_set.destroyed resource.destroyed permission_set_rule.destroyed])
      end

      test 'admin UI: an assignment whose grant cannot be recorded is not given' do
        bo = create_user(name: 'Bo')
        failing_store do
          assert_raises(Audit::EventNotRecordedError) do
            post "#{ROOT}/assignments", params: { user_id: bo.id, set_ids: [@set.id], expiry: 'never' }
          end
        end

        assert_not PermissionSetUser.exists?(user_id: bo.id)
      end

      test 'API: an update and a delete whose events cannot be written change nothing' do
        api_token!
        failing_store do
          assert_raises(Audit::EventNotRecordedError) do
            patch "#{ROOT}/api/permission_sets/#{@set.uuid}", params: { permission_set: { name: 'Renamed' } }, as: :json
          end
          assert_raises(Audit::EventNotRecordedError) do
            delete "#{ROOT}/api/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}/rules/#{@rule.uuid}", as: :json
          end
        end

        assert_equal 'Sales rep', @set.reload.name
        assert PermissionSetRule.exists?(@rule.id)
      end

      test 'API: generate_fields answers 422 and creates no field when the events cannot be written' do
        api_token!
        failing_store do
          post "#{ROOT}/api/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}/generate_fields", as: :json
        end

        assert_response 422
        assert_equal ['email'], @resource.resource_fields.reload.map(&:name)
      end

      test 'service: an expired assignment whose revocation cannot be recorded is kept' do
        @assignment.update_columns(expires_at: 1.day.ago)

        failing_store(%w[assignment.revoked]) do
          assert_raises(Audit::EventNotRecordedError) { Services::ExpiredAssignmentCleaner.call(actor: @admin) }
        end

        assert PermissionSetUser.exists?(@assignment.id)
        assert_empty AuditEvent.where(event: 'cleanup.expired_assignments')
      end

      test 'service: a clone whose provenance event cannot be written leaves no copy' do
        failing_store(%w[permission_set.cloned]) do
          assert_raises(Audit::EventNotRecordedError) do
            Services::PermissionSetCloner.call(permission_set: @set, attrs: { name: 'Copy' })
          end
        end

        assert_not PermissionSet.exists?(name: 'Copy')
        assert_empty AuditEvent.where(event: 'permission_set.created', record_label: 'Copy')
      end

      # --- every audited model, every action -------------------------------------------

      # model => [build the row, the update]: one entry per RecordsAuditEvents model.
      ROWS = {
        'PermissionSet' => [->(t) { t.send(:create_permission_set, name: 'Atomic set') }, { name: 'Renamed' }],
        'PermissionSetGroup' => [->(t) { t.send(:create_permission_set_group, name: 'Atomic group') }, { name: 'Renamed' }],
        'PermissionSetUser' => [->(t) { t.send(:create_permission_set_user, user: t.atomic_user, permission_set: t.atomic_set) },
                                { expires_at: 1.week.from_now }],
        'PermissionSetGroupUser' => [->(t) { PermissionSetGroupUser.create!(permission_set_group: t.atomic_group, user: t.atomic_user) },
                                     { reason: 'Changed' }],
        'Resource' => [->(t) { t.send(:create_resource, permission_set: t.atomic_set, name: 'Supplier') }, { create_access: true }],
        'ResourceField' => [->(t) { t.send(:create_resource_field, resource: t.atomic_resource, name: 'domain') }, { label: 'Web' }],
        'ResourceAction' => [->(t) { t.send(:create_resource_action, resource: t.atomic_resource, name: 'archive') }, { label: 'Archive' }],
        'PermissionSetRule' => [->(t) { t.send(:create_permission_set_rule, permission_set: t.atomic_set, resource: t.atomic_resource) },
                                { name: 'Renamed' }]
      }.freeze

      def atomic_user = @atomic_user ||= create_user(name: 'Atomic user')
      def atomic_set = @set
      def atomic_resource = @resource
      def atomic_group = @atomic_group ||= create_permission_set_group(name: 'Atomic group for members')

      test 'the table covers every audited model' do
        assert_equal TableLedger.models.map { |model| model.name.demodulize }.sort, ROWS.keys.sort
      end

      ROWS.each do |name, (build, update)|
        model = "PermissionForge::#{name}".constantize

        test "#{name}: a create whose #{model.audit_event_name(:create)} cannot be written inserts nothing" do
          assert_no_difference -> { model.unscoped.count } do
            failing_store([model.audit_event_name(:create)]) { assert_raises(Audit::EventNotRecordedError) { build.call(self) } }
          end
        end

        test "#{name}: an update whose #{model.audit_event_name(:update)} cannot be written changes nothing" do
          row = build.call(self)
          before = model.unscoped.find(row.id).attributes
          failing_store([model.audit_event_name(:update)]) { assert_raises(Audit::EventNotRecordedError) { row.update!(update) } }

          assert_equal before, model.unscoped.find(row.id).attributes
        end

        test "#{name}: a destroy whose #{model.audit_event_name(:destroy)} cannot be written deletes nothing" do
          row = build.call(self)
          failing_store([model.audit_event_name(:destroy)]) { assert_raises(Audit::EventNotRecordedError) { row.destroy! } }

          assert model.unscoped.exists?(row.id)
        end
      end

      # --- :report ----------------------------------------------------------------------

      test ':report lets an admin UI change through without its event and reports the failure' do
        PermissionForge.configuration.audit_change_failure_strategy = :report
        reports = error_reports do
          failing_store { patch "#{ROOT}/permission_sets/#{@set.id}/apply", params: { pf: { set: { description: 'Edited' } } } }
        end

        assert_response :redirect
        assert_equal 'Edited', @set.reload.description
        assert_empty audit_events_for(@set).where(event: 'permission_set.updated')
        assert_audit_failure_reported(reports, 'permission_set.updated')
      end

      test ':report lets an API change and a service through and reports each failure' do
        PermissionForge.configuration.audit_change_failure_strategy = :report
        api_token!
        @assignment.update_columns(expires_at: 1.day.ago)
        reports = error_reports do
          failing_store do
            delete "#{ROOT}/api/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}/rules/#{@rule.uuid}", as: :json
            Services::ExpiredAssignmentCleaner.call(actor: @admin)
          end
        end

        assert_not PermissionSetRule.exists?(@rule.id)
        assert_not PermissionSetUser.exists?(@assignment.id)
        %w[permission_set_rule.destroyed assignment.revoked cleanup.expired_assignments].each do |name|
          assert_audit_failure_reported(reports, name)
        end
      end

      private

      def assert_audit_failure_reported(reports, event)
        found = reports.any? { |_error, context| context[:source] == 'permission_forge.audit' && context.dig(:context, :event) == event }
        assert found, "a report for #{event} (got #{reports.map { |_e, c| c.dig(:context, :event) }.inspect})"
      end
    end

    # The same with real transactions: a host transaction that rescues the
    # failure still cannot commit the change.
    class AtomicityRealTransactionTest < ActiveSupport::TestCase
      include IntegrationSupport

      self.use_transactional_tests = false

      setup do
        @setup_baseline = AuditEvent.unscoped.maximum(:id).to_i
        @set = create_permission_set(name: "Atomicity #{SecureRandom.hex(3)}")
        @resource = create_resource(permission_set: @set, read_access: true)
        @baseline = AuditEvent.unscoped.maximum(:id).to_i
      end

      teardown do
        ResourceField.unscoped.where(resource_id: @resource.id).delete_all
        Resource.unscoped.where(id: @resource.id).delete_all
        PermissionSet.unscoped.where(id: @set.id).delete_all
        AuditEvent.unscoped.where(AuditEvent.arel_table[:id].gt(@setup_baseline)).delete_all
      end

      test 'a host transaction that rescues EventNotRecordedError is rolled back at commit, with its other writes' do
        error = assert_raises(Audit::EventNotRecordedError) do
          ActiveRecord::Base.transaction do
            failing_store(%w[permission_set.updated]) { @set.update!(name: 'Renamed') }
          rescue Audit::EventNotRecordedError
            @resource.update!(create_access: true) # the host carries on
          end
        end

        assert_match(/rolled back at commit/, error.message)
        assert_not_equal 'Renamed', @set.reload.name
        assert_not @resource.reload.create_access, 'the host\'s other write is rolled back with it'
        assert_empty AuditEvent.unscoped.where(AuditEvent.arel_table[:id].gt(@baseline))
      end

      test 'a service run inside a host transaction that rescues commits nothing' do
        assert_raises(Audit::EventNotRecordedError) do
          ActiveRecord::Base.transaction do
            failing_store(%w[resource_field.created]) { Services::ResourceFieldGenerator.call(resource: @resource) }
          rescue Audit::EventNotRecordedError
            nil
          end
        end

        assert_empty ResourceField.unscoped.where(resource_id: @resource.id)
        assert_empty AuditEvent.unscoped.where(AuditEvent.arel_table[:id].gt(@baseline))
      end
    end
  end
end
