# frozen_string_literal: true

require 'test_helper'
require_relative 'runtime_support'
require_relative '../nested_attribute_models'

module PermissionForge
  module Audit
    # field.access (one per record read), params.filtered and write.masked_skipped.
    class FieldDecisionEventsTest < ActiveSupport::TestCase
      include RuntimeSupport

      setup do
        @user = create_user(name: 'Ada')
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'Customer', edit_access: true)
        create_resource_field(resource: @resource, name: 'name', read_access: true, edit_access: true)
        create_resource_field(resource: @resource, name: 'email', label: 'Email', read_access: true, mask_access: true,
                              mask_strategy: 'email')
        create_resource_field(resource: @resource, name: 'domain', label: 'Domain', read_access: false)
        @customer = create_customer(name: 'Acme', email: 'john@example.com', domain: 'acme.test')
        @id = @customer.id
        @user.regenerate_permissions
        Current.user = @user
        @customer = Customer.find(@id)
      end

      teardown do
        PermissionForge.configuration.on_field_filtered = nil
      end

      def lists(payload)
        payload[:data].slice('hidden', 'masked', 'unconfigured', 'bypassed', 'passed')
      end

      # --- field.access ---------------------------------------------------------------

      test 'a getter is one read: record by class and id, the decision in its list' do
        payloads = published('field.access') do
          assert_equal 'j***@example.com', @customer.email
          assert_nil @customer.domain
          assert_equal 'Acme', @customer.name
        end

        assert_equal 3, payloads.size
        assert_equal [%w[Customer] * 3, [@id.to_s] * 3], [payloads.map { |p| p[:record_type] }, payloads.map { |p| p[:record_id] }]
        assert_equal({ 'hidden' => [], 'masked' => ['email'], 'unconfigured' => [], 'bypassed' => [], 'passed' => 0 }, lists(payloads[0]))
        assert_equal ['domain'], payloads[1][:data]['hidden']
        assert_equal 1, payloads[2][:data]['passed']
        assert_equal @user.id.to_s, payloads[0][:subject_user_id]
        assert_nil payloads[0][:record_label]
      end

      test 'attributes and as_json are one read each, listing every hidden and masked field' do
        payloads = published('field.access') do
          @customer.attributes
          @customer.as_json
          @customer.to_json
        end

        assert_equal 3, payloads.size
        payloads.each do |payload|
          assert_equal ['domain'], payload[:data]['hidden']
          assert_equal ['email'], payload[:data]['masked']
        end
      end

      test 'the payload names the record without reading it, and building it publishes nothing more' do
        payloads = published('field.access') { @customer.email }
        assert_equal 1, payloads.size
        assert_equal @customer.read_attribute_before_type_cast('uuid'), payloads.first[:record_uuid]
        assert_not_includes payloads.first.except(:objects).to_s, 'john@example.com'
        assert_not_includes payloads.first.except(:objects).to_s, 'acme.test'
      end

      test 'field_read is stored only when configured' do
        assert_no_difference -> { AuditEvent.where(event: 'field.access').count } do
          @customer.email
        end

        store_runtime(:denied, :field_read)
        assert_difference -> { AuditEvent.where(event: 'field.access').count }, 1 do
          @customer.as_json
        end
        event = assert_audit_event('field.access', record_type: 'Customer', record_id: @id.to_s, subject_user_id: @user.id.to_s)
        assert_equal ['domain'], event.data['hidden']
        assert_equal ['email'], event.data['masked']
      end

      test 'nothing is collected when nobody listens and the group is not stored' do
        frame_class = PermissionForge::Audit::FieldAccess::Frame
        frames = 0
        original = frame_class.method(:new)
        frame_class.define_singleton_method(:new) do |*args, **kw|
          frames += 1
          original.call(*args, **kw)
        end
        @customer.email
        @customer.as_json
        PermissionForge::Services::AttributeAccessGuard.call(resource_name: :Customer, attribute: :domain, raw_value: 'x', user: @user)
        assert_equal 0, frames
      ensure
        frame_class.singleton_class.send(:remove_method, :new)
      end

      test 'with no user the reads are bypassed' do
        Current.user = nil
        payloads = published('field.access') { @customer.domain }
        assert_equal ['domain'], payloads.first[:data]['bypassed']
        assert_equal 'unknown', payloads.first[:actor_type]
      end

      test 'with no user attributes publishes its bypassed fields like as_json' do
        Current.user = nil
        payloads = published('field.access') do
          assert_equal 'john@example.com', @customer.attributes['email']
          @customer.as_json
        end

        assert_equal 2, payloads.size
        assert_includes payloads[0][:data]['bypassed'], 'email'
        assert_includes payloads[0][:data]['bypassed'], 'domain'
        assert_empty payloads[1][:data]['bypassed'] - payloads[0][:data]['bypassed'], 'attributes lists what as_json lists'
      end

      test 'with no user and nobody listening attributes builds nothing' do
        Current.user = nil
        frame_class = PermissionForge::Audit::FieldAccess::Frame
        frames = 0
        original = frame_class.method(:new)
        frame_class.define_singleton_method(:new) do |*args, **kw|
          frames += 1
          original.call(*args, **kw)
        end
        assert_equal 'john@example.com', @customer.attributes['email']
        assert_equal 0, frames
      ensure
        frame_class.singleton_class.send(:remove_method, :new)
      end

      test 'the fields read in the clear are named, not only counted' do
        payloads = published('field.access') do
          @customer.name
          @customer.as_json
        end

        assert_equal [['name'], 1], payloads[0][:data].values_at('passed_fields', 'passed')
        assert_includes payloads[1][:data]['passed_fields'], 'name'
        assert_not_includes payloads[1][:data]['passed_fields'], 'email'
        assert_not_includes payloads[1][:data]['passed_fields'], 'domain'

        store_runtime(:denied, :field_read)
        @customer.name
        assert_equal ['name'], assert_audit_event('field.access', record_id: @id.to_s).data['passed_fields']
      end

      test 'an AttributeAccessGuard call of its own is a read of its own' do
        payloads = published('field.access') do
          PermissionForge::Services::AttributeAccessGuard.call(resource_name: :Customer, attribute: :domain, raw_value: 'x', user: @user)
        end
        assert_equal([['Customer', nil, ['domain']]], payloads.map { |p| [p[:record_type], p[:record_id], p[:data]['hidden']] })
      end

      test 'FiltersResponseAttributes is one read of the hash, with its id' do
        payloads = published('field.access') do
          result = PermissionForge::Services::FiltersResponseAttributes.call(
            attributes: { id: 7, name: 'Acme', email: 'john@example.com', domain: 'acme.test' }, resource_name: 'Customer', user: @user
          )
          assert_equal({ name: 'Acme', email: 'j***@example.com' }, result.except(:id))
        end
        assert_equal 1, payloads.size
        assert_equal %w[Customer 7], payloads.first.values_at(:record_type, :record_id)
        assert_equal({ 'hidden' => ['domain'], 'masked' => ['email'], 'unconfigured' => ['id'], 'bypassed' => [], 'passed' => 1 },
                     lists(payloads.first))
      end

      test 'FiltersResponseAttributes with no user lists every key' do
        Current.user = nil
        payloads = published('field.access') do
          PermissionForge::Services::FiltersResponseAttributes.call(attributes: { 'name' => 'x' }, resource_name: 'Customer', user: nil)
        end
        assert_equal ['name'], payloads.first[:data]['bypassed']
        PermissionForge.configuration.response_filter_nil_user_strategy = :block
        payloads = published('field.access') do
          PermissionForge::Services::FiltersResponseAttributes.call(attributes: { 'name' => 'x' }, resource_name: 'Customer', user: nil)
        end
        assert_equal ['name'], payloads.first[:data]['hidden']
      end

      test 'the legacy hook is called once per decision, in order, as before' do
        calls = []
        PermissionForge.configuration.on_field_filtered = lambda do |resource_name:, field_name:, action:, user:|
          calls << [field_name, action] if resource_name == 'Customer' && user == @user
        end
        @customer.attributes
        assert_equal(%i[name email domain], calls.map(&:first) & %i[name email domain])
        assert_equal(%i[passed masked hidden], calls.to_h.values_at(:name, :email, :domain))
      end

      # --- params.filtered -------------------------------------------------------------

      test 'dropped params are published with their paths, never their values' do
        supplier = create_resource(permission_set: @set, name: 'Supplier', edit_access: true)
        create_resource_field(resource: supplier, name: 'name', read_access: true, edit_access: true)
        @user.regenerate_permissions
        params = { name: 'x', domain: 'secret-value', supplier_attributes: { name: 'S', note: 'n' },
                   contacts_attributes: [{ name: 'a', price: 1 }, 'not a record'], lines_attributes: [{ name: 'a' }] }
        payloads = published('params.filtered') do
          result = PermissionForge::Services::PermitsAttributes.call(resource: PfNestedCustomer.find(@id), permitted_params: params)
          assert_equal 'x', result[:name]
          assert_not result.key?(:domain)
        end

        assert_equal 1, payloads.size
        payload = payloads.first
        assert_equal %w[Customer] + [@id.to_s], payload.values_at(:record_type, :record_id)
        assert_equal 'field_access', payload[:data]['reason']
        assert_includes payload[:data]['dropped'], 'domain'
        assert_includes payload[:data]['dropped'], 'supplier_attributes.note'
        assert_includes payload[:data]['dropped'], 'contacts_attributes.*.price'
        assert_includes payload[:data]['dropped'], 'contacts_attributes.*', 'an element that is no record'
        assert_includes payload[:data]['dropped'], 'lines_attributes', 'no such nested association: a field, dropped whole'
        assert_not_includes payload.except(:objects).to_s, 'secret-value'
      end

      test 'nothing dropped publishes nothing, and no user drops every key' do
        assert_empty(published('params.filtered') do
          PermissionForge::Services::PermitsAttributes.call(resource: Customer, permitted_params: { name: 'x' })
        end)

        Current.user = nil
        payloads = published('params.filtered') do
          assert_equal({}, PermissionForge::Services::PermitsAttributes.call(resource: Customer, permitted_params: { name: 'x', email: 'y' }))
        end
        assert_equal [%w[nil_user], [%w[name email]]], [payloads.map { |p| p[:data]['reason'] }, payloads.map { |p| p[:data]['dropped'] }]
        assert_equal ['Customer', nil], payloads.first.values_at(:record_type, :record_id)
      end

      test 'params_filtered is stored only when configured' do
        assert_no_difference -> { AuditEvent.where(event: 'params.filtered').count } do
          PermissionForge::Services::PermitsAttributes.call(resource: Customer, permitted_params: { domain: 'x' })
        end
        store_runtime(:params_filtered)
        assert_difference -> { AuditEvent.where(event: 'params.filtered').count }, 1 do
          PermissionForge::Services::PermitsAttributes.call(resource: Customer, permitted_params: { domain: 'x' })
        end
      end

      # --- write.masked_skipped --------------------------------------------------------

      test 'a masked value written back is write.masked_skipped under :skip and :raise' do
        masked = @customer.email
        payloads = published('write.masked_skipped') do
          @customer.email = masked
          assert_equal 'john@example.com', @customer.read_attribute_before_type_cast('email')
        end
        assert_equal 1, payloads.size
        assert_equal({ 'model' => 'Customer', 'attribute' => 'email', 'protection' => 'skip', 'detected_by' => 'ledger' },
                     payloads.first[:data])
        assert_equal ['Customer', @id.to_s, @user.id.to_s], payloads.first.values_at(:record_type, :record_id, :subject_user_id)

        PermissionForge.configuration.masked_write_protection = :raise
        fresh = Customer.find(@id)
        payloads = published('write.masked_skipped') do
          assert_raises(PermissionForge::Concerns::MaskedAttributes::MaskedWriteError) { fresh.email = 'j***@example.com' }
        end
        assert_equal %w[raise persisted_value], payloads.first[:data].values_at('protection', 'detected_by')
      end
    end
  end
end
