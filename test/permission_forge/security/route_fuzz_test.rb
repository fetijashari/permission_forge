# frozen_string_literal: true

require 'test_helper'
require_relative 'shipped_api_authorization'

module PermissionForge
  module Security
    # Every engine route (admin screens, API, assets) with every parameter the
    # engine reads set to one hostile shape at a time: a Hash, an Array, a NUL
    # byte, numbers past a bigint, control characters… Each request must
    # answer below 500, or raise an exception Rails maps to a 4xx. (From the
    # WS5 review's fuzz: a crafted request is never a 500.) A second pass puts
    # the shapes inside the attribute hashes (permission_set[name], pf[set]
    # [description], rule[value] …): no NUL byte may reach a stored record
    # (PostgreSQL refuses one in text). A third pass sends each admin route an
    # Accept header no browser sends (WEB-N6): the admin answers HTML (or the
    # export the action has), never a missing-template 500.
    #
    # Two more passes say what a value must be read *as*, not only "below
    # 500": EXPECT names, per route and parameter, the answer every hostile
    # shape of that one parameter gets (the rest of the request valid); the
    # duplicate-insert pass plays the uniqueness race on every route that
    # creates a row of a uniquely indexed table.
    class RouteFuzzTest < ActionDispatch::IntegrationTest
      include ShippedApiAuthorization
      include MethodStubs

      ROOT = '/permission_forge'

      POISON = {
        'hash' => { 'a' => '1' },
        'array' => ['x', { 'b' => '2' }],
        'nul' => "a\u0000b",
        'huge' => '9' * 40,
        'unicode' => "#{'ü' * 300}\u{1F600}",
        'blank' => '',
        'mixed' => '1abc',
        'nested' => { 'a' => { 'b' => { 'c' => ['d'] } } },
        'overbig' => '9223372036854775808',
        'cntl' => "\e[0m\r\n"
      }.freeze

      PARAMS = %w[user_id user_ids ids set_ids permission_set_id expires_at expiry custom_date page per_page q filter tab
                  return_to pf field rule group resource resource_field resource_action permission_set_rule permission_set
                  permission_set_group name identifiers explain_user_id key preset locale bulk_action confirmation flag
                  reason type start_from_granting start_from_muting theme dismiss_help from to event actor record_type
                  search change_person set_q sort description is_active is_muting requires_session_flag allowed_ips
                  allowed_hours_start allowed_hours_end hours_enabled grant_all is_editable views open why who days
                  permission_set_group_id model_name op rule_id cleanup privacy new v focus changed level
                  requires_session_flag_custom sync].freeze

      # Attribute hashes the engine reads, and the attributes put inside them.
      NESTED_KEYS = %w[permission_set resource resource_field resource_action permission_set_rule permission_set_group
                       pf field rule group].freeze
      NESTED_SHAPES = { 'nul' => "a\u0000b", 'hash' => { 'a' => '1' }, 'array' => ['x', { 'b' => '2' }] }.freeze
      ACCEPTS = %w[application/json text/csv application/xml text/plain */*;q=0.1].freeze
      MODELS = [PermissionForge::PermissionSet, PermissionForge::PermissionSetUser, PermissionForge::PermissionSetGroup,
                PermissionForge::PermissionSetGroupUser, PermissionForge::Resource, PermissionForge::ResourceField,
                PermissionForge::ResourceAction, PermissionForge::PermissionSetRule].freeze

      # Per route ("controller#action") and parameter, what every hostile
      # shape of that parameter is read as, the rest of the request valid
      # (#expected_failure): a paging typo is the default page, an id, a
      # time, a flag or a bulk action the API cannot read a 422 keyed by the
      # parameter. Every API index route gets PAGING.
      PAGING = { 'per_page' => :default_per_page, 'page' => :first_page }.freeze
      EXPECT = {
        'permission_forge/api/permission_set_users#create' => { 'user_id' => :keyed_refusal, 'expires_at' => :keyed_refusal_or_no_end },
        'permission_forge/api/permission_set_group_users#create' => { 'user_id' => :keyed_refusal },
        'permission_forge/api/resources#generate_fields' => { 'grant_all' => :keyed_refusal },
        'permission_forge/api/permission_set_users#bulk' => { 'bulk_action' => :keyed_refusal }
      }.freeze
      # Shapes that are a positive whole number: a page they name is a page.
      NUMERIC_SHAPES = %w[huge overbig].freeze

      # [verb, path spec, controller, action] for every engine route.
      def self.routes
        PermissionForge::Engine.routes.routes.filter_map { |route| route_entry(route) }.uniq
      end

      def self.route_entry(route)
        verb = route.verb.to_s.split('|').first.to_s.downcase
        return if verb.empty?

        requirements = route.requirements
        [verb, route.path.spec.to_s.sub('(.:format)', ''), requirements[:controller], requirements[:action]]
      end

      # EXPECT's entries for a route; every API index route pages.
      def self.expectations_for(controller, action)
        return PAGING if action == 'index' && controller.start_with?('permission_forge/api')

        EXPECT.fetch("#{controller}##{action}", {})
      end

      # The competing row of the uniqueness race: the record's own
      # attributes, another uuid, past the callbacks (it stands for a row
      # another process committed).
      def self.commit_twin(record)
        klass = record.class
        attributes = record.attributes.except(klass.primary_key).compact.merge('uuid' => SecureRandom.uuid)
        klass.unscoped.insert_all!([attributes])
      end

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @set = create_permission_set(name: 'Sales')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email', read_access: true)
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        @action = create_resource_action(resource: @resource)
        @group = create_permission_set_group(name: 'Team')
        @user = create_user(name: 'Ana')
        @other = create_user(name: 'Bo')
        @assignment = create_permission_set_user(user: @user, permission_set: @set)
        @member = PermissionForge::PermissionSetGroupUser.create!(permission_set_group: @group, user: @user)
        @event = PermissionForge::AuditEvent.order(:id).last
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      routes.each_with_index do |(verb, spec, controller, action), index|
        test "#{format('%03d', index)} #{verb.upcase} #{spec} (#{controller}##{action}) answers every shape below 500" do
          path = build_path(spec, controller)
          failures = POISON.filter_map do |shape, value|
            code = status_of(verb, path, PARAMS.index_with { value })
            "#{shape}: #{code}" unless code.is_a?(Integer) && code < 500
          end

          assert_empty failures, "#{verb.upcase} #{path}"
        end

        test "#{format('%03d', index)} #{verb.upcase} #{spec} (#{controller}##{action}) keeps nested shapes out" do
          path = build_path(spec, controller)
          failures = NESTED_SHAPES.filter_map do |shape, value|
            code = status_of(verb, path, NESTED_KEYS.index_with { nested(value) })
            "#{shape}: #{code}" unless code.is_a?(Integer) && code < 500
          end

          assert_empty failures, "#{verb.upcase} #{path}"
          assert_empty stored_nuls, "#{verb.upcase} #{path} stored a NUL byte"
        end

        expectations_for(controller, action).each do |param, kind|
          test "#{format('%03d', index)} #{verb.upcase} #{spec} (#{controller}##{action}) reads every shape of #{param} as #{kind}" do
            path = build_path(spec, controller)
            failures = POISON.filter_map do |shape, value|
              send(verb, path, params: valid_params_for(controller, action).merge(param => value))
              failure = expected_failure(kind, param, shape)
              "#{shape}: #{failure}" if failure
            end

            assert_empty failures, "#{verb.upcase} #{path} #{param}"
          end
        end

        next if controller.start_with?('permission_forge/api')

        test "#{format('%03d', index)} #{verb.upcase} #{spec} (#{controller}##{action}) answers any Accept header below 500" do
          path = build_path(spec, controller)
          failures = ACCEPTS.product([{}, PARAMS.index_with { '' }]).filter_map do |accept, params|
            code = status_of(verb, path, params, headers: { 'ACCEPT' => accept })
            "#{accept} #{params.empty? ? 'no params' : 'blank params'}: #{code}" unless code.is_a?(Integer) && code < 500
          end

          assert_empty failures, "#{verb.upcase} #{path}"
        end
      end

      # --- the uniqueness race -------------------------------------------------
      #
      # Two requests pass the uniqueness validation together and the unique
      # index refuses the second INSERT (ActiveRecord::RecordNotUnique). Played
      # at the exact moment — the validation itself commits the competing row,
      # so the request's own INSERT is the one refused — on every route that
      # creates a row of an indexed table. The API answers the validation's own
      # 422, keyed by the attribute; the admin goes back to the form's page
      # with the message; neither is a 500.

      test 'duplicate insert: POST /api/permission_sets/:set/users is the validation 422' do
        racing_uniqueness { post "#{ROOT}/api/permission_sets/#{@set.uuid}/users", params: { user_id: @other.id } }
        assert_api_duplicate(PermissionForge::PermissionSetUser.new(permission_set: @set, user: @user))
      end

      test 'duplicate insert: POST /api/permission_set_groups/:group/users is the validation 422' do
        racing_uniqueness { post "#{ROOT}/api/permission_set_groups/#{@group.uuid}/users", params: { user_id: @other.id } }
        assert_api_duplicate(PermissionForge::PermissionSetGroupUser.new(permission_set_group: @group, user: @user))
      end

      test 'duplicate insert: POST /api/permission_sets/:set/resources is the validation 422' do
        racing_uniqueness do
          post "#{ROOT}/api/permission_sets/#{@set.uuid}/resources", params: { resource: { name: 'Supplier', read_access: true } }
        end
        assert_api_duplicate(PermissionForge::Resource.new(permission_set: @set, name: 'Customer'))
      end

      test 'duplicate insert: POST /api/permission_sets/:set/resources/:resource/fields is the validation 422' do
        racing_uniqueness do
          post "#{ROOT}/api/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}/fields",
               params: { resource_field: { name: 'domain', label: 'Domain' } }
        end
        assert_api_duplicate(PermissionForge::ResourceField.new(resource: @resource, name: 'email', label: 'E'))
      end

      test 'duplicate insert: POST /permission_sets/:id/resources goes back to the form with the message' do
        referer = "http://www.example.com#{ROOT}/permission_sets/#{@set.id}/resources/new"
        racing_uniqueness do
          post "#{ROOT}/permission_sets/#{@set.id}/resources", params: { model_name: 'Supplier', preset: 'read' },
                                                               headers: { 'HTTP_REFERER' => referer }
        end
        assert_admin_duplicate(referer, PermissionForge::Resource.new(permission_set: @set, name: 'Customer'))
      end

      test 'duplicate insert: POST /permission_sets/:id/resources/:model/sync goes back to the form with the message' do
        referer = "http://www.example.com#{ROOT}/permission_sets/#{@set.id}/resources/Customer"
        racing_uniqueness do
          post "#{ROOT}/permission_sets/#{@set.id}/resources/Customer/sync", params: { level: 'read' },
                                                                             headers: { 'HTTP_REFERER' => referer }
        end
        assert_admin_duplicate(referer, PermissionForge::ResourceField.new(resource: @resource, name: 'email', label: 'E'))
      end

      test 'duplicate insert: POST /assignments goes back to the form with the message' do
        referer = "http://www.example.com#{ROOT}/assignments/new?user_id=#{@other.id}"
        racing_uniqueness do
          post "#{ROOT}/assignments", params: { user_id: @other.id, set_ids: [@set.id], expiry: 'never' },
                                      headers: { 'HTTP_REFERER' => referer }
        end
        assert_admin_duplicate(referer, PermissionForge::PermissionSetUser.new(permission_set: @set, user: @user))
      end

      test 'duplicate insert: POST /groups/:id/members goes back to the group with the message' do
        referer = "http://www.example.com#{ROOT}/groups/#{@group.id}"
        racing_uniqueness do
          post "#{ROOT}/groups/#{@group.id}/members", params: { user_id: @other.id }, headers: { 'HTTP_REFERER' => referer }
        end
        assert_admin_duplicate(referer, PermissionForge::PermissionSetGroupUser.new(permission_set_group: @group, user: @user))
      end

      test 'duplicate insert: without a Referer the admin goes back to its home page' do
        racing_uniqueness { post "#{ROOT}/groups/#{@group.id}/members", params: { user_id: @other.id } }
        assert_response :see_other
        assert_redirected_to "#{ROOT}/"
        assert flash[:alert].present?
      end

      private

      # Runs the block with every uniqueness validation replaced by the race:
      # instead of checking, it commits the competing row (the other
      # request's, as the index then sees it), so the caller's own INSERT is
      # the one the index refuses. The original check is put back after.
      def racing_uniqueness
        validator = ActiveRecord::Validations::UniquenessValidator
        original = validator.instance_method(:validate_each)
        replace_method(validator, :validate_each) { |record, _attribute, _value| RouteFuzzTest.commit_twin(record) }
        yield
      ensure
        replace_method(validator, :validate_each, original)
      end

      # The 422 the validation gives for `twin` (a duplicate of a stored row).
      def assert_api_duplicate(twin)
        twin.validate
        assert_response :unprocessable_entity
        assert_equal({ 'error' => { 'status' => 422, 'messages' => twin.errors.messages.as_json } }, JSON.parse(response.body))
      end

      def assert_admin_duplicate(referer, twin)
        twin.validate
        assert_response :see_other
        assert_redirected_to referer
        assert_includes flash[:alert].to_s, PermissionForge::Admin::ErrorSentence.first(twin.errors)
      end

      # The rest of a request whose one parameter is poisoned: valid.
      def valid_params_for(controller, action)
        case "#{controller}##{action}"
        when 'permission_forge/api/permission_set_users#create' then { 'user_id' => @other.id }
        when 'permission_forge/api/permission_set_users#bulk' then { 'user_ids' => [@other.id] }
        else {}
        end
      end

      # nil when the answer is what `kind` expects, else what it was
      # (#default_per_page_failure, #first_page_failure, #keyed_refusal_failure,
      # #keyed_refusal_or_no_end_failure).
      def expected_failure(kind, param, shape)
        send("#{kind}_failure", param, shape, response.status, JSON.parse(response.body))
      end

      # The default page size; a number past the maximum is the maximum.
      def default_per_page_failure(_param, shape, status, json)
        config = PermissionForge.configuration
        per_page = json.dig('meta', 'pagination', 'per_page')
        expected = NUMERIC_SHAPES.include?(shape) ? config.api_max_per_page : config.api_default_per_page
        "#{status}, per_page #{per_page.inspect}" unless status == 200 && per_page == expected
      end

      # The first page; a number names a page.
      def first_page_failure(_param, shape, status, json)
        page = json.dig('meta', 'pagination', 'page')
        "#{status}, page #{page.inspect}" unless status == 200 && (page == 1 || NUMERIC_SHAPES.include?(shape))
      end

      # A 422 keyed by the parameter.
      def keyed_refusal_failure(param, _shape, status, json)
        "#{status}: #{json.to_s[0, 160]}" unless status == 422 && json.dig('error', 'messages', param).is_a?(Array)
      end

      # A blank end date is no end date (created); anything else unreadable a 422.
      def keyed_refusal_or_no_end_failure(param, shape, status, json)
        return keyed_refusal_failure(param, shape, status, json) unless shape == 'blank'

        "#{status}: #{json.to_s[0, 160]}" unless status == 201
      end

      def nested(value)
        { 'name' => value, 'description' => value, 'label' => value, 'field_value' => value, 'value' => value,
          'failure_message' => value, 'mask_strategy' => value, 'field_name' => value,
          'set' => { 'name' => value, 'description' => value } }
      end

      # [model, attribute] of every stored String holding a NUL byte.
      def stored_nuls
        MODELS.flat_map do |model|
          model.unscoped.flat_map do |record|
            record.attributes.select { |_, v| v.is_a?(String) && v.include?("\0") }.keys.map { |name| "#{model.name}##{name}" }
          end
        end
      end

      def status_of(verb, path, params, headers: {})
        send(verb, path, params: params, headers: headers)
        response.status
      rescue StandardError => e
        code = ActionDispatch::ExceptionWrapper.status_code_for_exception(e.class.name)
        code >= 500 ? "#{e.class}: #{e.message[0, 160]}" : code
      end

      def id_for(controller)
        {
          'permission_forge/people' => @user.id, 'permission_forge/assignments' => @assignment.id,
          'permission_forge/permission_sets' => @set.id, 'permission_forge/permission_set_groups' => @group.id,
          'permission_forge/resource_actions' => @action.id, 'permission_forge/permission_set_rules' => @rule.id,
          'permission_forge/audit_events' => @event&.uuid, 'permission_forge/permission_set_group_users' => @member.id
        }.fetch(controller, 1)
      end

      def identifier_for(controller)
        {
          'permission_forge/api/permission_sets' => @set.uuid, 'permission_forge/api/resources' => @resource.uuid,
          'permission_forge/api/resource_fields' => @field.uuid, 'permission_forge/api/resource_actions' => @action.uuid,
          'permission_forge/api/permission_set_rules' => @rule.uuid,
          'permission_forge/api/permission_set_users' => @assignment.uuid,
          'permission_forge/api/permission_set_groups' => @group.uuid,
          'permission_forge/api/permission_set_group_users' => @member.uuid,
          'permission_forge/api/audit_events' => @event&.uuid
        }.fetch(controller, 'x')
      end

      def build_path(spec, controller)
        {
          ':permission_set_identifier' => @set.uuid, ':resource_identifier' => @resource.uuid,
          ':permission_set_group_identifier' => @group.uuid, ':permission_set_id' => @set.id,
          ':resource_model' => 'Customer', ':model' => 'Customer', ':key' => 'email', ':group_id' => @group.id,
          ':file' => 'pf_admin.css', ':identifier' => identifier_for(controller), ':id' => id_for(controller),
          '(/*path)' => '/no/such/endpoint'
        }.reduce(ROOT + spec) { |path, (name, value)| path.gsub(name, value.to_s) }
      end
    end
  end
end
