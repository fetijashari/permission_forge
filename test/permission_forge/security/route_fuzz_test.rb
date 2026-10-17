# frozen_string_literal: true

require 'test_helper'
require_relative 'shipped_api_authorization'
require_relative 'fuzz_params'

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
    #
    # The all-at-once passes cannot reach a parameter that is only read when
    # another one is valid (`days` behind `tab=audit`, `rule[remove_step]`
    # behind a rule form): the single passes poison, per route, each
    # parameter its controller reads (FuzzParams, found in the source) one
    # at a time inside each valid request of #valid_contexts, then each
    # attribute of each attribute section of those requests; the API also
    # gets them as a JSON body, `null` included. The guard test fails when a
    # parameter the engine reads is missing from PARAMS, or a section from
    # every valid request (R2 review, P1-1).
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
                  requires_session_flag_custom sync actor_id actor_type category correlation_id subject_user_id
                  record_id record_uuid views].freeze
      # Parameters that are path segments (a query value of the same name is
      # overridden by the path).
      PATH_PARAMS = %w[id permission_set_id resource_model model key group_id file identifier permission_set_identifier
                       resource_identifier permission_set_group_identifier path].freeze

      # The single passes: one parameter (or one attribute of a section) at a
      # time; the API's JSON bodies add `null`.
      SINGLE_SHAPES = POISON.slice('hash', 'array', 'nul', 'blank', 'mixed', 'overbig').merge('negative' => '-1').freeze
      JSON_SHAPES = SINGLE_SHAPES.merge('null' => nil).freeze

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
        'permission_forge/api/permission_set_users#bulk' => { 'bulk_action' => :keyed_refusal, 'user_ids' => :keyed_refusal },
        'permission_forge/api/permission_sets#clone' => { 'name' => :keyed_refusal_unless_text },
        'permission_forge/api/permission_set_groups#clone' => { 'name' => :keyed_refusal_unless_text }
      }.freeze
      # The shapes no attribute of an API section takes, and the ones only
      # some do (Api::InputShapes): a list or an object never; `true` only a
      # boolean column or a rule's value; `1.5` only a rule's value.
      WRONG_SHAPES = { 'list' => ['x'], 'object' => { 'a' => '1' }, 'true' => true, 'fraction' => 1.5 }.freeze
      # The model each API attribute section writes.
      SECTION_MODELS = {
        'permission_set' => PermissionForge::PermissionSet, 'permission_set_group' => PermissionForge::PermissionSetGroup,
        'resource' => PermissionForge::Resource, 'resource_field' => PermissionForge::ResourceField,
        'resource_action' => PermissionForge::ResourceAction, 'permission_set_rule' => PermissionForge::PermissionSetRule
      }.freeze
      # Shapes that are a positive whole number: a page they name is a page.
      NUMERIC_SHAPES = %w[huge overbig].freeze

      # Valid requests (#valid_contexts), built in the test (instance_exec):
      # the records of the setup.
      ADMIN_RULE = { 'path' => %w[orders], 'field_name' => 'name', 'operator' => 'equal', 'value' => 'x', 'name' => 'Rule' }.freeze
      ACTION_FORM = { 'resource_action' => { 'name' => 'export', 'label' => 'Export' } }.freeze
      API_RULE = { 'permission_set_rule' => { 'name' => 'r', 'field_name' => 'name', 'field_value' => 'x', 'operator' => 'equal' } }.freeze
      API_FIELD = { 'resource_field' => { 'name' => 'phone', 'label' => 'Phone', 'read_access' => true } }.freeze
      API_ACTION = { 'resource_action' => { 'name' => 'export', 'label' => 'Export' } }.freeze
      VALID_CONTEXTS = {
        'permission_forge/permission_sets#show' => -> { [{}, { 'tab' => 'audit' }, { 'tab' => 'assignments' }, { 'tab' => 'conditions' }] },
        'permission_forge/permission_sets#create' => -> { [{ 'name' => 'New set' }] },
        'permission_forge/permission_sets#review' => -> { [{ 'pf' => { 'set' => { 'description' => 'x' } } }] },
        'permission_forge/permission_sets#apply' => -> { [{ 'pf' => { 'set' => { 'description' => 'x' } } }] },
        'permission_forge/permission_sets#conditions' =>
          -> { [{ 'hours_enabled' => '1', 'allowed_hours_start' => '9', 'allowed_hours_end' => '18', 'allowed_ips' => '10.0.0.1' }] },
        'permission_forge/people#show' => -> { [{}, { 'tab' => 'effective' }, { 'tab' => 'audit' }] },
        'permission_forge/resources#show' => -> { [{}, { 'tab' => 'actions' }, { 'tab' => 'rules' }] },
        'permission_forge/resources#create' => -> { [{ 'model_name' => 'Supplier', 'preset' => 'read' }] },
        'permission_forge/resources#sync' => -> { [{ 'level' => 'read' }, { 'op' => 'remove_missing' }] },
        'permission_forge/resource_fields#update' => -> { [{ 'field' => { 'level' => 'read', 'label' => 'E-mail' } }] },
        'permission_forge/resource_actions#create' => -> { [ACTION_FORM] },
        'permission_forge/resource_actions#update' => -> { [ACTION_FORM] },
        'permission_forge/permission_set_rules#create' => -> { [{ 'rule' => ADMIN_RULE }] },
        'permission_forge/permission_set_rules#update' => -> { [{ 'rule' => ADMIN_RULE }] },
        'permission_forge/permission_set_rules#refresh' => -> { [{ 'rule' => ADMIN_RULE.merge('remove_step' => '1') }] },
        'permission_forge/permission_set_rules#new' => -> { [{}, { 'rule_id' => '1' }] },
        'permission_forge/permission_set_groups#create' => -> { [{ 'name' => 'New team' }] },
        'permission_forge/permission_set_groups#update' => -> { [{ 'group' => { 'name' => 'Renamed', 'is_active' => '1' } }] },
        'permission_forge/permission_set_groups#add_set' => -> { [{ 'permission_set_id' => @set.id }] },
        'permission_forge/permission_set_group_users#create' => -> { [{ 'user_id' => @other.id }] },
        'permission_forge/assignments#new' => -> { [{ 'user_id' => @user.id }, { 'permission_set_id' => @set.id }] },
        'permission_forge/assignments#create' =>
          -> { [{ 'user_id' => @other.id, 'set_ids' => [@set.id], 'expiry' => 'never' }] },
        'permission_forge/assignments#update' => -> { [{ 'expiry' => 'extend30' }] },
        'permission_forge/assignments#restore' =>
          -> { [{ 'permission_set_id' => @set.id, 'user_id' => @user.id }] },
        'permission_forge/assignments#undo' => -> { [{ 'ids' => [@assignment.id] }] },
        'permission_forge/bulk_assignments#preview' => -> { [{ 'identifiers' => 'Bo' }] },
        'permission_forge/bulk_assignments#create' => -> { [{ 'identifiers' => 'Bo', 'expiry' => 'never' }] },
        'permission_forge/bulk_assignments#revoke' => -> { [{ 'user_ids' => [@user.id] }] },
        'permission_forge/people#erase' => -> { [{ 'confirmation' => 'Ana' }] },
        'permission_forge/preferences#update' => -> { [{ 'theme' => 'dark' }] },
        'permission_forge/api/permission_sets#create' => -> { [{ 'permission_set' => { 'name' => 'Other' } }] },
        'permission_forge/api/permission_sets#update' => -> { [{ 'permission_set' => { 'name' => 'Other' } }] },
        'permission_forge/api/resources#create' => -> { [{ 'resource' => { 'name' => 'Supplier', 'read_access' => true } }] },
        'permission_forge/api/resources#update' => -> { [{ 'resource' => { 'read_access' => true } }] },
        'permission_forge/api/resource_fields#create' => -> { [API_FIELD] },
        'permission_forge/api/resource_fields#update' => -> { [API_FIELD] },
        'permission_forge/api/resource_actions#create' => -> { [API_ACTION] },
        'permission_forge/api/resource_actions#update' => -> { [API_ACTION] },
        'permission_forge/api/permission_set_rules#create' => -> { [API_RULE] },
        'permission_forge/api/permission_set_rules#update' => -> { [API_RULE] },
        'permission_forge/api/permission_set_groups#create' => -> { [{ 'permission_set_group' => { 'name' => 'Other team' } }] },
        'permission_forge/api/permission_set_groups#update' => -> { [{ 'permission_set_group' => { 'name' => 'Other team' } }] },
        'permission_forge/api/permission_set_users#create' => -> { [{ 'user_id' => @other.id }] },
        'permission_forge/api/permission_set_users#bulk' =>
          -> { [{ 'user_ids' => [@other.id], 'bulk_action' => 'assign' }] },
        'permission_forge/api/permission_set_group_users#create' => -> { [{ 'user_id' => @other.id }] }
      }.freeze

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

        test "#{format('%03d', index)} #{verb.upcase} #{spec} (#{controller}##{action}) answers each read parameter alone below 500" do
          path = build_path(spec, controller)
          params = FuzzParams.read_by(controller) - PATH_PARAMS
          failures = valid_contexts(controller, action).flat_map do |base|
            params.flat_map { |param| single_failures(verb, path, controller, base) { |value| base.merge(param => value) }.map { "#{param} #{_1}" } }
          end

          assert_empty failures, "#{verb.upcase} #{path}"
        end

        test "#{format('%03d', index)} #{verb.upcase} #{spec} (#{controller}##{action}) answers each section attribute alone below 500" do
          path = build_path(spec, controller)
          failures = valid_contexts(controller, action).flat_map do |base|
            sections_of(base).flat_map do |section, attributes|
              attributes.flat_map do |attribute|
                single_failures(verb, path, controller, base) { |value| base.merge(section => base[section].merge(attribute => value)) }
                  .map { "#{section}[#{attribute}] #{_1}" }
              end
            end
          end

          assert_empty failures, "#{verb.upcase} #{path}"
          assert_empty stored_nuls, "#{verb.upcase} #{path} stored a NUL byte"
        end

        if controller.start_with?('permission_forge/api') && verb != 'get'
          test "#{format('%03d', index)} #{verb.upcase} #{spec} (#{controller}##{action}) answers a wrong shape of each " \
               'section attribute with a 422 keyed by it' do
            path = build_path(spec, controller)
            failures = valid_contexts(controller, action).flat_map do |base|
              sections_of(base).flat_map { |section, attributes| wrong_shape_failures(verb, path, base, section, attributes) }
            end

            assert_empty failures, "#{verb.upcase} #{path}"
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

      # --- the fuzz table covers what the engine reads ------------------------

      test 'every parameter the engine reads is in the fuzz table' do
        missing = FuzzParams.all_reads.reject { |name, _| PARAMS.include?(name) || PATH_PARAMS.include?(name) }

        assert_empty missing.transform_values(&:uniq),
                     'add these to PARAMS (and a valid request to #valid_contexts when they are read behind another parameter)'
      end

      test 'every attribute section the engine reads has a valid request that reaches it' do
        reached = self.class.routes.flat_map { |_, _, controller, action| valid_contexts(controller, action).flat_map(&:keys) }.uniq

        assert_empty FuzzParams.sections.keys - reached, 'add a valid request with this section to #valid_contexts'
      end

      # The scanner itself: parameters read only behind another, and through
      # a reader the scanner must know.
      test 'the parameter scan finds the reads behind another parameter' do
        assert_includes FuzzParams.read_by('permission_forge/permission_sets'), 'days'
        assert_includes FuzzParams.read_by('permission_forge/audit_events'), 'correlation_id'
        assert_includes FuzzParams.sections['rule'], 'remove_step'
        assert_includes FuzzParams.sections['permission_set_rule'], 'include_nulls'
        assert_includes FuzzParams.read_by('permission_forge/api/permission_sets'), 'permission_set'
      end

      # The API reads its sections through pf_record_attributes: the scan
      # must find every key each one takes, or the single passes above stop
      # poisoning them without a word. Each API route's valid request runs
      # once with Api::InputShapes.call recording what it was asked to read.
      test 'the parameter scan finds every key pf_record_attributes takes' do
        taken = Hash.new { |hash, key| hash[key] = [] }
        original = PermissionForge::Api::InputShapes.method(:call)
        replace_singleton_method(PermissionForge::Api::InputShapes, :call) do |attrs, model, keys, **options|
          taken[model] |= keys.map(&:to_s)
          original.call(attrs, model, keys, **options)
        end
        self.class.routes.each do |verb, spec, controller, action|
          next unless controller.start_with?('permission_forge/api') && verb != 'get'

          valid_contexts(controller, action).each { |base| status_of(verb, build_path(spec, controller), base, as: :json) }
        end
      ensure
        replace_singleton_method(PermissionForge::Api::InputShapes, :call, original) if original
        assert_equal SECTION_MODELS.values.sort_by(&:name), taken.keys.sort_by(&:name), 'every API section was read'
        taken.each do |model, keys|
          section = SECTION_MODELS.key(model)
          assert_empty keys - FuzzParams.sections.fetch(section, []), "#{section}: keys the scan does not find"
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
        valid_contexts(controller, action).first
      end

      # Valid requests to each route: every branch that reads more
      # parameters (a tab, a form section) gets one. The single passes poison
      # each read parameter, and each attribute of each section, inside every
      # one of them.
      def valid_contexts(controller, action)
        instance_exec(&VALID_CONTEXTS.fetch("#{controller}##{action}") { -> { [{}] } })
      end

      # The attribute sections of a valid request, with every attribute the
      # engine reads in each (FuzzParams.sections) and the ones the request sets.
      def sections_of(base)
        base.select { |_, value| value.is_a?(Hash) }.to_h do |section, value|
          [section, (FuzzParams.sections.fetch(section, []) | value.keys)]
        end
      end

      # The shapes of one poisoned value (`yield` builds the request from it)
      # answered at 500 or more; an API route that takes a body gets them as
      # JSON as well (`null` included).
      def single_failures(verb, path, controller, _base, &build)
        single_requests(verb, controller, &build).filter_map do |shape, params, as|
          code = status_of(verb, path, params, as: as)
          "#{shape}: #{code}" unless code.is_a?(Integer) && code < 500
        end
      end

      def single_requests(verb, controller)
        requests = SINGLE_SHAPES.map { |shape, value| [shape, yield(value), nil] }
        return requests unless controller.start_with?('permission_forge/api') && verb != 'get'

        requests + JSON_SHAPES.map { |shape, value| ["#{shape} (json)", yield(value), :json] }
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

      # [attribute shape: answer] for each wrong shape (WRONG_SHAPES) of each
      # attribute of `section` that is not a 422 keyed by the attribute, the
      # rest of the request valid, as JSON.
      def wrong_shape_failures(verb, path, base, section, attributes)
        model = SECTION_MODELS.fetch(section)
        attributes.flat_map do |attribute|
          WRONG_SHAPES.except(*taken_shapes(model, attribute)).filter_map do |shape, value|
            send(verb, path, params: base.merge(section => base[section].merge(attribute => value)), as: :json)
            failure = keyed_refusal_failure(attribute, shape, response.status, JSON.parse(response.body))
            "#{section}[#{attribute}] #{shape}: #{failure}" if failure
          end
        end
      end

      # The WRONG_SHAPES an attribute takes: `true` for a boolean column,
      # `true` and `1.5` for a rule's value (a JSON scalar is its text).
      def taken_shapes(model, attribute)
        return %w[true fraction] if model == PermissionForge::PermissionSetRule && attribute == 'field_value'

        model.columns_hash[attribute]&.type == :boolean ? %w[true] : []
      end

      # Text is read (a copy's name: created, or the name's own 422); anything
      # else is a 422 keyed by the parameter.
      def keyed_refusal_unless_text_failure(param, shape, status, json)
        return keyed_refusal_failure(param, shape, status, json) unless POISON.fetch(shape).is_a?(String)

        "#{status}: #{json.to_s[0, 160]}" unless status == 201 || (status == 422 && json.dig('error', 'messages', param))
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

      def status_of(verb, path, params, headers: {}, as: nil)
        send(verb, path, params: params, headers: headers, as: as)
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
