# frozen_string_literal: true

require 'test_helper'
require_relative '../sti_models'

module PermissionForge
  module Concerns
    # Masking with nobody signed in, inside and outside a web request
    # (GitHub issue #11). masked_attributes_nil_user_strategy:
    #
    # - :hide_in_requests hides every guarded attribute in a web request with
    #   nobody signed in (a public page, a before_action before sign-in, a
    #   middleware below WebRequest::Middleware) and keeps the stored values
    #   in jobs, rake and the console; the user model stays readable;
    # - :bypass (the library default) returns the stored values everywhere,
    #   and inside a web request records each such read: the runtime event
    #   field.unmasked_without_user (group :bypass) once per request per model
    #   and attribute, and one SECURITY warning per model and process.
    class MaskedAttributesInRequestsTest < ActionDispatch::IntegrationTest
      PAGE = '/pf_public/customers'
      EVENT = 'field.unmasked_without_user'

      setup do
        Current.user = nil
        @set = create_permission_set(name: 'Customer readers')
        customers = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_resource_field(resource: customers, name: 'name', label: 'Name', read_access: true)
        create_resource_field(resource: customers, name: 'email', label: 'Email', read_access: true,
                              mask_access: true, mask_strategy: 'email')
        @customer = PermissionForge.without_permission_scope { create_customer(name: 'Acme', email: 'sales@acme.test') }
        @log = StringIO.new
        Rails.logger = ActiveSupport::Logger.new(@log)
      end

      teardown { Current.user = nil }

      def config = PermissionForge.configuration

      def page_json
        get "#{PAGE}/#{@customer.id}"
        assert_response :ok
        response.parsed_body
      end

      def notifications
        seen = []
        subscriber = ActiveSupport::Notifications.subscribe("#{EVENT}.permission_forge") { |*, payload| seen << payload }
        yield
        seen
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      def stored_events
        baseline = AuditEvent.unscoped.maximum(:id) || 0
        yield
        AuditEvent.unscoped.where(event: EVENT).where(AuditEvent.arel_table[:id].gt(baseline)).order(:id).to_a
      end

      def warnings = @log.string.lines.grep(/unmasked_without_user|read in a web request with nobody signed in/)

      # --- :hide_in_requests -----------------------------------------------------------

      test ':hide_in_requests hides every guarded attribute in a web request with nobody signed in, before_action included' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests
        body = page_json

        assert_nil body['before_action'], 'a read before sign-in (a tenant lookup in a before_action) is in the request'
        assert_nil body['email']
        assert_nil body['name'], 'configured or not: nobody is signed in to be granted it'
        assert_equal({ 'id' => @customer.id }, body['as_json'], 'only the primary key, as under :hide')
        assert_equal({ 'id' => @customer.id }, body['attributes'])
        assert_not WebRequest.active?, 'the request is over once its response is'
      end

      test ':hide_in_requests hides a read in a middleware below WebRequest::Middleware, before any controller' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests
        customer = @customer
        host_middleware = ->(_env) { [200, {}, [customer.email.inspect]] }
        _status, _headers, body = WebRequest::Middleware.new(host_middleware).call(Rack::MockRequest.env_for('/tenant'))

        assert_equal ['nil'], body.to_enum.to_a
        body.close
      end

      test ':hide_in_requests keeps the stored values outside a web request: a job, the console, a runner, rake' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests

        assert_equal 'sales@acme.test', @customer.email, 'console / runner / rake: no request'
        assert_equal 'sales@acme.test', Rails.application.executor.wrap { @customer.reload.email }, 'a job run by a worker'
        assert_equal 'Acme', @customer.as_json['name']
        assert_equal 'sales@acme.test', @customer.attributes['email']
      end

      test ':hide_in_requests leaves the user model readable in a web request, for sign-in' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests
        config.user_class = 'PfStiBugTicket'
        tickets = create_resource(permission_set: @set, name: 'PfStiTicket', read_access: true)
        create_resource_field(resource: tickets, name: 'email', label: 'Email', read_access: true, mask_access: true)
        signing_in, other = PermissionForge.without_permission_scope do
          [PfStiBugTicket.create!(title: 'Ann', email: 'ann@example.test'), PfStiTicket.create!(title: 'Cat', email: 'cat@example.test')]
        end

        WebRequest.within(Rack::MockRequest.env_for('/sign_in')) do
          assert_equal 'ann@example.test', signing_in.email, 'the user model (user_class) is exempt'
          assert_equal 'Ann', signing_in.as_json['title']
          assert_nil other.email, 'its base class is not the user model'
          assert_nil @customer.email
        end
      end

      test 'a job run with perform_now inside the request is in the request' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests

        WebRequest.within(Rack::MockRequest.env_for('/signup')) do
          assert_nil Rails.application.executor.wrap { @customer.email }, 'the executor run joins the request'
        end
      end

      test 'a signed-in user is judged by their permissions under :hide_in_requests, as before' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests
        user = create_user
        create_permission_set_user(user: user, permission_set: @set)
        Current.user = user

        WebRequest.within(Rack::MockRequest.env_for('/account')) do
          assert_equal 'Acme', @customer.name
          assert_equal 's***@acme.test', @customer.email
        end
      end

      test 'explain says what happens with nobody signed in, in a request and outside one' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests
        outside = MaskedAttributes.explain(@customer, :email)
        inside = WebRequest.within(Rack::MockRequest.env_for('/x')) { MaskedAttributes.explain(@customer, :email) }

        assert_equal [false, 'sales@acme.test'], outside.values_at(:in_web_request, :returned_value)
        assert_equal [true, nil], inside.values_at(:in_web_request, :returned_value)
        decisions = capture_io do
          @decisions = [MaskedAttributes.explain_all(@customer),
                        WebRequest.within({}) { MaskedAttributes.explain_all(@customer) }].map do |rows|
            rows.find { |row| row[:attribute] == 'email' }[:decision]
          end
        end
        assert decisions
        assert_equal %i[no_user_bypassed no_user_hidden], @decisions
      end

      # --- writing after a hidden read (a webhook or a public form that normalizes) -------------

      def normalize(customer)
        customer.email = customer.email&.downcase
        customer.name = customer.name.to_s.strip
        customer.domain = customer.email.to_s.split('@').last
        customer.save!
      end

      test 'a value worked out from an attribute read as hidden with nobody signed in is not saved over it' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests
        config.audit_runtime_events = %i[denied params_filtered]
        PermissionForge.without_permission_scope { @customer.update_columns(name: '  Acme ', domain: 'acme.test') }
        customer = Customer.unscoped.find(@customer.id)

        WebRequest.within(Rack::MockRequest.env_for('/webhook')) { normalize(customer) }

        stored = Customer.unscoped.where(id: @customer.id).pick(:name, :email, :domain)
        assert_equal ['  Acme ', 'sales@acme.test'], stored.first(2), 'name and email keep their stored values'
        # The hazard the docs name: domain was never read, so its new value
        # (derived from the hidden email) cannot be told from a real one.
        assert_nil stored.last
        assert_audit_event('write.masked_skipped', data: { 'attribute' => 'name', 'detected_by' => 'hidden_without_user' })
      end

      test 'under masked_write_protection :raise such a write raises, and an attribute never read is written' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests
        config.masked_write_protection = :raise
        customer = Customer.unscoped.find(@customer.id)

        WebRequest.within(Rack::MockRequest.env_for('/form')) do
          customer.update!(supplier_id: 7, name: 'Typed in')
          assert_raises(MaskedAttributes::MaskedWriteError) { customer.name = customer.name.to_s.strip }
        end

        assert_equal [7, 'Typed in'], Customer.unscoped.where(id: @customer.id).pick(:supplier_id, :name)
      ensure
        config.masked_write_protection = :skip
      end

      # A test-only model on the customers table with a default set as the
      # record is built (no Resource row: with nobody signed in it is masked
      # all the same).
      class DefaultedCustomer < ApplicationRecord
        self.table_name = 'customers'
        include PermissionForge::Concerns::MaskedAttributes

        after_initialize { self.domain ||= 'default.test' if new_record? }
      end

      # A new record whose column has a database default: the default counts
      # as its value in the database, but nothing is stored to hide yet. The
      # table is made once per process, outside any test transaction.
      ActiveRecord::Schema.define do
        create_table :pf_house_domains, force: true do |t|
          t.string :domain, default: 'house.test'
        end
      end

      class HouseDomainCustomer < ApplicationRecord
        self.table_name = 'pf_house_domains'
        include PermissionForge::Concerns::MaskedAttributes
      end

      def in_signup(&) = WebRequest.within(Rack::MockRequest.env_for('/signup'), &)
      def stored(record, *columns) = record.class.unscoped.where(id: record.id).pick(*columns)

      test 'nothing real was hidden: a new record and an empty column take a default or a fill-if-blank' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests
        empty = Customer.unscoped.find(PermissionForge.without_permission_scope { create_customer(name: nil).id })

        new_record = in_signup { Customer.new(email: 'a@x.test').tap { |c| c.name ||= 'Jane' }.tap(&:save!) }
        initialized = in_signup do
          Customer.find_or_initialize_by(uuid: 'u-b').tap { |c| c.name = 'Jane' if c.name.blank? }.tap(&:save!)
        end
        in_signup { empty.tap { |c| c.name = 'Jane' if c.name.blank? }.save! }
        defaulted = in_signup { DefaultedCustomer.new(name: 'Jane').tap(&:save!) }
        chosen = in_signup { HouseDomainCustomer.new.tap { |c| c.domain = 'chosen.test' if c.domain.blank? }.tap(&:save!) }

        assert_equal 'Jane', stored(new_record, :name), 'A: a new record'
        assert_equal 'Jane', stored(initialized, :name), 'B: find_or_initialize_by'
        assert_equal 'Jane', stored(empty, :name), 'C: a NULL column hid nothing'
        assert_equal 'default.test', stored(defaulted, :domain), 'F: an after_initialize default'
        assert_equal 'chosen.test', stored(chosen, :domain), 'a new record with an attribute default stores nothing yet'
      end

      test 'a stored value read hidden is kept; overwriting it without a sign-in is refused, recorded and logged once' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests
        config.audit_runtime_events = %i[denied params_filtered]
        customer = Customer.unscoped.find(@customer.id)

        in_signup { customer.tap { |c| c.name = 'Jane' if c.name.blank? }.save! }
        assert_equal 'Acme', stored(customer, :name), 'D: the real name is kept'

        2.times do
          changing = Customer.unscoped.find(@customer.id)
          in_signup { changing.tap { |c| c.email.inspect && (c.email = 'new@x.test') }.save! }
        end
        assert_equal 'sales@acme.test', stored(customer, :email), 'G: refused'
        assert_audit_event('write.masked_skipped', data: { 'attribute' => 'email', 'detected_by' => 'hidden_without_user' })
        refusals = @log.string.lines.grep(/Customer#email was not written/)
        assert_equal 1, refusals.size, @log.string
        assert_includes refusals.first, 'sign in a system user'
      end

      test 'the hidden reads are forgotten on reload and after a save' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests
        customer = Customer.unscoped.find(@customer.id)

        in_signup do
          customer.name
          customer.reload
          customer.update!(name: 'After reload')
        end
        assert_equal 'After reload', stored(customer, :name)

        in_signup do
          customer.name
          customer.update!(supplier_id: 3)
          customer.update!(name: 'After save')
        end
        assert_equal 'After save', stored(customer, :name)

        in_signup do
          customer.name
          customer.update!(name: 'Refused')
        end
        assert_equal 'After save', stored(customer, :name), 'read hidden and not saved or reloaded since: refused'
      end

      test 'an inspect does not count as a hidden read, and :bypass protects nothing it did not hide' do
        config.masked_attributes_nil_user_strategy = :hide_in_requests
        customer = Customer.unscoped.find(@customer.id)

        WebRequest.within(Rack::MockRequest.env_for('/error')) do
          customer.inspect
          customer.update!(name: 'Renamed')
        end
        config.masked_attributes_nil_user_strategy = :bypass
        WebRequest.within(Rack::MockRequest.env_for('/form')) { customer.update!(name: customer.name.upcase) }

        assert_equal 'RENAMED', Customer.unscoped.find(@customer.id).name
      end

      # --- :bypass records what :hide_in_requests would hide ------------------------------

      test ':bypass returns the stored values in a web request and publishes field.unmasked_without_user once per request per attribute' do
        assert_equal :bypass, config.masked_attributes_nil_user_strategy

        published = notifications { 2.times { page_json } }
        body = response.parsed_body

        assert_equal 'sales@acme.test', body['email']
        assert_equal 'sales@acme.test', body['before_action']
        per_request = published.map { |payload| payload[:data]['attribute'] }
        assert_equal per_request.uniq.size * 2, per_request.size, 'each attribute once per request, in each request'
        assert_includes per_request, 'email'
        assert_includes per_request, 'name'
        assert_not_includes per_request, 'id', 'the primary key is never guarded'
        email = published.find { |payload| payload[:data]['attribute'] == 'email' }
        assert_equal({ 'model' => 'Customer', 'attribute' => 'email', 'method' => 'GET', 'path' => "#{PAGE}/#{@customer.id}",
                       'endpoint' => 'pf_public_pages#show' }, email[:data])
        assert_equal ['access', 'runtime', 'Customer', nil, nil], email.values_at(:category, :source, :record_type, :record_id, :subject_user_id)
        assert_equal false, email[:stored], 'the bypass group is not stored by default'
        assert email[:request_id].present?, 'the request id of the web request'
      end

      test 'field.unmasked_without_user is stored with the bypass group, never with a value' do
        config.audit_runtime_events = %i[denied bypass]

        events = stored_events { page_json }

        email = events.find { |event| event.data['attribute'] == 'email' }
        assert email, events.map(&:data).inspect
        assert_equal %w[access runtime Customer], [email.category, email.source, email.record_type]
        assert_equal 'pf_public_pages#show', email.data['endpoint']
        assert_not_includes events.map(&:attributes).to_json, 'sales@acme.test'
        attributes = events.map { |event| event.data['attribute'] }
        assert_equal attributes.uniq, attributes, 'once per request per attribute'
      end

      test 'attributes and as_json record too, though no getter is called' do
        config.audit_runtime_events = %i[denied bypass]

        events = stored_events do
          WebRequest.within(Rack::MockRequest.env_for('/feed')) do
            assert_equal 'sales@acme.test', @customer.attributes['email']
            Audit::Runtime.reset!
            assert_equal 'sales@acme.test', @customer.as_json['email']
          end
        end

        assert_equal(2, events.count { |event| event.data['attribute'] == 'email' })
      end

      test 'nothing is recorded outside a web request, for the user model, or under :hide_in_requests and :hide' do
        config.audit_runtime_events = %i[denied bypass]
        config.user_class = 'Customer'

        events = stored_events do
          assert_equal 'sales@acme.test', @customer.email
          WebRequest.within(Rack::MockRequest.env_for('/x')) { assert_equal 'sales@acme.test', @customer.email }
          config.user_class = 'User'
          %i[hide_in_requests hide].each do |strategy|
            config.masked_attributes_nil_user_strategy = strategy
            WebRequest.within(Rack::MockRequest.env_for('/x')) { assert_nil @customer.email }
          end
        end

        assert_empty events
        assert_empty warnings
      end

      test 'a SECURITY warning names the model, the attribute and the request, once per model and process' do
        2.times { page_json }

        assert_equal 1, warnings.size, @log.string
        line = warnings.first
        assert_includes line, 'SECURITY warning:'
        assert_match(%r{Customer#\w+ was read in a web request with nobody signed in \(GET #{PAGE}/#{@customer.id}}, line)
        assert_includes line, ':hide_in_requests'
        assert_not_includes line, 'sales@acme.test'
      end

      test 'inspect in a request publishes nothing and warns nothing: a debugging read' do
        published = notifications do
          WebRequest.within(Rack::MockRequest.env_for('/error')) { assert_includes @customer.inspect, 'sales@acme.test' }
        end

        assert_empty published
        assert_empty warnings
      end

      test 'models are warned about by name: a reloaded class, or a Resource name, does not warn again' do
        WebRequest.within(Rack::MockRequest.env_for('/a')) { @customer.email }
        WebRequest.within(Rack::MockRequest.env_for('/b')) { Audit::UnmaskedWithoutUser.note('Customer', :email) }

        assert_equal 1, warnings.size
        assert Audit::UnmaskedWithoutUser.warned.key?('Customer')
      end

      test 'with nobody listening and the bypass group not stored, a read in a request builds nothing and allocates no more' do
        built = 0
        instrument = Audit.method(:instrument)
        replace_singleton_method(Audit, :instrument) { |*| built += 1 }
        customer = @customer
        read = -> { 200.times { customer.email } }
        WebRequest.within(Rack::MockRequest.env_for('/warm')) { read.call } # the per-process warning, once

        outside = allocations(&read)
        inside = WebRequest.within(Rack::MockRequest.env_for('/x')) { allocations(&read) }

        assert_equal 0, built
        assert_nil ExecutionState[Audit::Runtime::ONCE_KEY], 'not even the once-per-request memo'
        assert_operator inside, :<=, outside

        hashes = -> { 50.times { customer.attributes } }
        outside = allocations(&hashes)
        inside = WebRequest.within(Rack::MockRequest.env_for('/x')) { allocations(&hashes) }
        assert_operator inside, :<=, outside, 'attributes returns the stored hash at once once the model was warned about'
      ensure
        replace_singleton_method(Audit, :instrument, instrument)
      end

      private

      def allocations
        GC.disable
        before = GC.stat(:total_allocated_objects)
        yield
        GC.stat(:total_allocated_objects) - before
      ensure
        GC.enable
      end
    end
  end
end
