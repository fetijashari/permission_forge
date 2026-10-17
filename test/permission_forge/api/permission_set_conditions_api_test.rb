# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    # Field test round 6 (d-api, steps 16/18/38): the API permitted
    # `allowed_ips` as a scalar only, so a JSON array was dropped without a
    # word — POST answered 201 with `allowed_ips: null`, PATCH 200 changing
    # nothing — and an "office only" granting set then applied from any IP.
    #
    # The guard: every condition attribute of a Permission Set, in every
    # JSON shape a client may send, either round-trips (the answer and the
    # row hold the normalised value) or is refused with a 422 keyed by the
    # attribute. A 2xx that stored something else is the defect.
    class PermissionSetConditionsApiTest < ActionDispatch::IntegrationTest
      HEADERS = { 'CONTENT_TYPE' => 'application/json' }.freeze

      # attribute => { shape => [sent value, what a round trip stores] }; :refused
      # where the shape is one the API does not take. nil stores nil (clears).
      SHAPES = {
        'allowed_ips' => {
          string: ["10.0.0.0/8\n192.168.0.0/16", '10.0.0.0/8,192.168.0.0/16'],
          array: [%w[192.168.0.0/16 172.16.0.0/12], '192.168.0.0/16,172.16.0.0/12'],
          number: [42, :refused],
          null: [nil, nil],
          object: [{ 'cidr' => '10.0.0.0/8' }, :refused],
          boolean: [true, :refused]
        },
        'requires_session_flag' => {
          string: %w[mfa_verified mfa_verified],
          array: [%w[mfa], :refused],
          number: [7, :refused],
          null: [nil, nil],
          object: [{ 'flag' => 'mfa' }, :refused],
          boolean: [true, :refused]
        },
        'allowed_hours_start' => {
          string: ['9', 9],
          array: [[9], :refused],
          number: [9, 9],
          null: [nil, nil],
          object: [{ 'hour' => 9 }, :refused],
          boolean: [true, :refused]
        },
        'allowed_hours_end' => {
          string: ['17', 17],
          array: [[17], :refused],
          number: [17, 17],
          null: [nil, nil],
          object: [{ 'hour' => 17 }, :refused],
          boolean: [false, :refused]
        }
      }.freeze

      # The other attributes that make the row valid whatever one attribute
      # says: the hours come in pairs, so a single hour is sent with its
      # partner (a null clears both).
      def payload(attribute, value)
        base = { 'name' => "Shape #{SecureRandom.hex(3)}", 'allowed_ips' => '10.0.0.0/8', 'allowed_hours_start' => 1, 'allowed_hours_end' => 2 }
        base['allowed_hours_start'] = base['allowed_hours_end'] = nil if attribute.start_with?('allowed_hours') && value.nil?
        base.merge(attribute => value)
      end

      def json = JSON.parse(response.body)

      def assert_stored(expected, actual, message)
        expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
      end

      def assert_round_trip_or_refusal(attribute, shape, sent, stored, set)
        if stored == :refused
          assert_refused(attribute, shape, sent, set)
        else
          assert_round_trip(attribute, shape, stored, set)
        end
      end

      def assert_refused(attribute, shape, sent, set)
        assert_response :unprocessable_content, "#{attribute} as #{shape}: expected a 422"
        assert json.dig('error', 'messages').key?(attribute), "#{attribute} as #{shape}: the 422 is keyed by the attribute: #{json}"
        assert_not_equal sent, set&.reload&.public_send(attribute), "#{attribute} as #{shape}: nothing is stored" if set
      end

      def assert_round_trip(attribute, shape, stored, set)
        assert_includes [200, 201], response.status, "#{attribute} as #{shape}: #{json}"
        assert_stored stored, set.reload.public_send(attribute), "#{attribute} as #{shape}: the row holds the normalised value"
        assert_stored stored, json.dig('data', attribute), "#{attribute} as #{shape}: the answer shows it"
      end

      SHAPES.each do |attribute, shapes|
        shapes.each do |shape, (sent, stored)|
          test "POST #{attribute} as #{shape} round-trips or is refused" do
            post '/permission_forge/api/permission_sets', params: { permission_set: payload(attribute, sent) }.to_json, headers: HEADERS

            set = PermissionForge::PermissionSet.find_by(uuid: json.dig('data', 'uuid')) if response.status == 201
            assert_round_trip_or_refusal(attribute, shape, sent, stored, set)
          end

          test "PATCH #{attribute} as #{shape} round-trips or is refused" do
            set = create_permission_set(name: 'Office only', allowed_ips: '203.0.113.0/24', allowed_hours_start: 1,
                                        allowed_hours_end: 2, requires_session_flag: 'before')
            patch "/permission_forge/api/permission_sets/#{set.uuid}", params: { permission_set: payload(attribute, sent) }.to_json,
                                                                       headers: HEADERS

            assert_round_trip_or_refusal(attribute, shape, sent, stored, set)
          end
        end
      end

      test 'the serializer shows the entries as the engine reads them' do
        set = create_permission_set(name: 'Listed', allowed_ips: "10.0.0.0/8\n192.168.0.0/16")

        get "/permission_forge/api/permission_sets/#{set.uuid}"

        assert_equal '10.0.0.0/8,192.168.0.0/16', json.dig('data', 'allowed_ips')
        assert_equal %w[10.0.0.0/8 192.168.0.0/16], json.dig('data', 'allowed_ip_list')
      end

      test 'an entry that is not an IP is a 422 keyed allowed_ips, however the list is shaped' do
        [['10.0.0.0/8', 'office'], '10.0.0.0/8, office'].each do |list|
          post '/permission_forge/api/permission_sets', params: { permission_set: payload('allowed_ips', list) }.to_json, headers: HEADERS

          assert_response :unprocessable_content, list.inspect
          assert_match(/office/, json.dig('error', 'messages', 'allowed_ips').join, list.inspect)
        end
      end

      # Review R1 #12: `[]` or `[""]` cleared the condition without a word;
      # null (or "") is how a client clears it.
      test 'an IP list with no entry is a 422 saying null clears the condition' do
        set = create_permission_set(name: 'Office only', allowed_ips: '203.0.113.0/24')
        [[], [''], [' ', ','], ' , '].each do |list|
          patch "/permission_forge/api/permission_sets/#{set.uuid}", params: { permission_set: { allowed_ips: list } }.to_json,
                                                                     headers: HEADERS

          assert_response :unprocessable_content, list.inspect
          assert_match(/null/, json.dig('error', 'messages', 'allowed_ips').join, list.inspect)
          assert_equal '203.0.113.0/24', set.reload.allowed_ips, list.inspect
        end
        patch "/permission_forge/api/permission_sets/#{set.uuid}", params: { permission_set: { allowed_ips: nil } }.to_json, headers: HEADERS

        assert_response :ok
        assert_nil set.reload.allowed_ips
      end

      test 'the recorded scenario: an office-only granting set written as an array grants from the office only' do
        post '/permission_forge/api/permission_sets',
             params: { permission_set: { name: 'Office only', allowed_ips: ['10.0.0.0/8'] } }.to_json, headers: HEADERS
        assert_response :created
        set = PermissionForge::PermissionSet.find_by!(uuid: json.dig('data', 'uuid'))

        assert set.conditional?
        evaluator = PermissionForge::Services::PermissionSetConditionEvaluator
        assert evaluator.call(permission_set: set, context: { ip: '10.1.2.3' })
        assert_not evaluator.call(permission_set: set, context: { ip: '203.0.113.9' })
      end
    end
  end
end
