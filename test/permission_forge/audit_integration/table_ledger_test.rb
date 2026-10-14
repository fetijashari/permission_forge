# frozen_string_literal: true

require_relative 'integration_support'

module PermissionForge
  module AuditIntegration
    # The ledger the route and service coverage tests compare every request
    # with: it must see a change no event explains, whatever wrote it.
    class TableLedgerTest < ActiveSupport::TestCase
      include IntegrationSupport

      setup do
        @set = create_permission_set(name: 'Sales rep')
        @resource = create_resource(permission_set: @set, read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email')
      end

      test 'the ledger covers the eight audited models' do
        assert_equal %w[PermissionSet PermissionSetGroup PermissionSetGroupUser PermissionSetRule PermissionSetUser Resource
                        ResourceAction ResourceField], TableLedger.models.map { |model| model.name.demodulize }.sort
      end

      test 'audited writes are explained' do
        assert_explained do
          @set.update!(description: 'Edited')
          create_resource_field(resource: @resource, name: 'domain').update!(label: 'Web')
          @field.destroy!
          PermissionSetUser.create!(user: create_user, permission_set: @set).destroy!
        end
      end

      test 'writes past callbacks are not' do
        problems = unexplained do
          @set.update_columns(description: 'Silently')
          ResourceField.where(id: @field.id).delete_all
          ResourceField.insert_all([{ uuid: SecureRandom.uuid, name: 'ghost', resource_id: @resource.id, account_id: @set.account_id }])
          @resource.touch
        end

        assert_match(/PermissionSet ##{@set.id} changed description without an event/, problems.join("\n"))
        assert_match(/ResourceField ##{@field.id} was deleted without resource_field.destroyed/, problems.join("\n"))
        assert_match(/ResourceField #\d+ was inserted without resource_field.created/, problems.join("\n"))
        assert_match(/Resource ##{@resource.id} changed updated_at without an event/, problems.join("\n"))
      end

      test 'an event that lies about the change, or names a row nothing changed, is not explained' do
        problems = unexplained do
          @set.update!(description: 'Edited')
          @set.update_columns(description: 'Something else')
          Audit.record('resource.updated', record: @resource, data: { 'changes' => { 'read_access' => [true, false] } })
        end

        assert_match(/description \("Edited" vs "Something else"\)/, problems.join("\n"))
        assert_match(/resource.updated name PermissionForge::Resource ##{@resource.id}, but no such row changed/, problems.join("\n"))
      end

      private

      def unexplained(&)
        ledger_events(&)
        before, after, events = @ledger
        TableLedger.unexplained(before, after, events)
      end

      def assert_explained(&)
        ledger_events(&)
        assert_tables_explained('audited writes')
      end
    end
  end
end
