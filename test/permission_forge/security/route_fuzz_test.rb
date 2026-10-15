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
    class RouteFuzzTest < ActionDispatch::IntegrationTest
      include ShippedApiAuthorization

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

      private

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
