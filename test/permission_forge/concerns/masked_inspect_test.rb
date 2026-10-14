require 'test_helper'
require 'pp'

module PermissionForge
  module Concerns
    # Pre-release review core-security #7: `inspect` printed masked and hidden
    # values in full, so a record in a log line, an error report or a console
    # leaked what its getters withhold. inspect, pretty_print and
    # attribute_for_inspect show what the current user's getters return.
    class MaskedInspectTest < ActiveSupport::TestCase
      class GuardedCustomer < ::Customer
        include PermissionForge::Concerns::MaskedAttributes

        def self.name = 'Customer'
      end

      setup do
        @user = create_user
        set = create_permission_set
        create_permission_set_user(user: @user, permission_set: set)
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        create_resource_field(resource: resource, name: 'name', read_access: true)
        create_resource_field(resource: resource, name: 'email', label: 'Email', read_access: true, mask_access: true,
                              mask_strategy: 'email')
        create_resource_field(resource: resource, name: 'domain', label: 'Domain', read_access: false)
        @user.regenerate_permissions
        PermissionForge.configuration.unconfigured_field_strategy = :pass_through
        customer = GuardedCustomer.create!(uuid: SecureRandom.uuid, name: 'Acme', email: 'secret@acme.com', domain: 'hidden.example')
        Current.user = @user
        @customer = GuardedCustomer.find(customer.id)
      end

      test 'inspect shows what the getters return: masked values masked, hidden ones hidden' do
        text = @customer.inspect

        assert_includes text, 'name: "Acme"'
        assert_includes text, 'email: "s***@acme.com"'
        assert_includes text, 'domain: nil'
        assert_not_includes text, 'secret@acme.com'
        assert_not_includes text, 'hidden.example'
      end

      test 'pretty_print shows the same' do
        text = @customer.pretty_inspect

        assert_includes text, 's***@acme.com'
        assert_not_includes text, 'secret@acme.com'
        assert_not_includes text, 'hidden.example'
      end

      test 'attribute_for_inspect goes through the guard' do
        assert_equal '"s***@acme.com"', @customer.attribute_for_inspect(:email)
        assert_equal 'nil', @customer.attribute_for_inspect('domain')
        assert_equal '"Acme"', @customer.attribute_for_inspect(:name)
        assert_equal @customer.id.inspect, @customer.attribute_for_inspect(:id), 'the primary key is never masked'
      end

      test 'a record inside a message, an Array or a Hash leaks nothing either' do
        assert_not_includes "could not save #{@customer.inspect}", 'hidden.example'
        assert_not_includes [@customer].inspect, 'secret@acme.com'
        assert_not_includes({ record: @customer }.inspect, 'hidden.example')
      end

      test 'without a user inspect shows the stored values, as the getters do' do
        Current.user = nil

        assert_includes @customer.inspect, 'secret@acme.com'
        assert_includes @customer.pretty_inspect, 'hidden.example'
      end

      test 'a new record and a partially loaded one inspect as Rails would' do
        assert_includes GuardedCustomer.new(name: 'New').inspect, 'name: "New"'
        partial = GuardedCustomer.select(:id, :name).find(@customer.id)

        assert_includes partial.inspect, 'name: "Acme"'
        assert_not_includes partial.inspect, 'email'
      end

      # inspect runs inside error reporters and rescue blocks, often in the
      # failed transaction itself: it must never raise, and must never fall
      # back to the raw value (review MINOR-4).
      test 'inspect never raises: when the permission hash cannot be read it shows the hidden value, never the raw one' do
        def @user.permissions_hash = raise(ActiveRecord::StatementInvalid, 'PG::InFailedSqlTransaction')
        Current.user = @user

        text = nil
        assert_nothing_raised { text = @customer.inspect }
        assert_includes text, "id: #{@customer.id}"
        assert_includes text, 'email: nil'
        assert_includes text, 'name: nil'
        assert_not_includes text, 'secret@acme.com'
        assert_not_includes text, 'Acme'
        assert_nothing_raised { @customer.pretty_inspect }
        assert_not_includes @customer.pretty_inspect, 'hidden.example'
      end

      # A debugging read is not a field read: no field.access event, no
      # on_field_filtered call, however many attributes (review MINOR-5).
      test 'inspect and pretty_print are not audited reads' do
        PermissionForge.configuration.audit_runtime_events = %i[denied field_read]
        calls = []
        PermissionForge.configuration.on_field_filtered = ->(args) { calls << args }
        count = -> { PermissionForge::AuditEvent.unscoped.where(event: 'field.access').count }

        assert_no_difference(count) do
          @customer.inspect
          @customer.pretty_inspect
          @customer.attribute_for_inspect(:email)
        end
        assert_empty calls

        before = count.call
        @customer.email
        assert_operator count.call, :>, before, 'a getter still is one'
      ensure
        PermissionForge.configuration.audit_runtime_events = %i[denied]
        PermissionForge.configuration.on_field_filtered = nil
      end

      test 'the host filter_attributes still apply on top' do
        klass = Class.new(GuardedCustomer) { def self.name = 'Customer' }
        klass.filter_attributes = [:name]

        text = klass.find(@customer.id).inspect
        assert_includes text, 'name: [FILTERED]'
        assert_includes text, 'email: "s***@acme.com"'
      end
    end
  end
end
