# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    # Every API lookup goes through BaseController#find_record. Under
    # api_record_identifier = :id only a string of digits names a record:
    # Rails casts '1abc' (and a uuid that starts with digits) to 1, so the raw
    # value would answer for another record. A NUL byte never reaches the
    # database (PostgreSQL raises on it).
    class RecordIdentifierTest < ActionDispatch::IntegrationTest
      BASE = '/permission_forge/api'

      setup do
        @config = PermissionForge.configuration
        @saved = @config.api_record_identifier
        @set = create_permission_set(name: 'Support')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
      end

      teardown { @config.api_record_identifier = @saved }

      # Moving a row to id 2**63-1 also moves InnoDB's AUTO_INCREMENT counter
      # (MySQL 8 persists it, and a rollback does not restore it): every
      # later insert into the table would then fail. Once the test's
      # transaction has rolled back, put the counter back at the table's
      # largest id + 1 (ALTER TABLE would commit an open transaction, so
      # never before).
      def after_teardown
        super
      ensure
        reset_auto_increment if @auto_increment_moved
      end

      def reset_auto_increment
        connection = PermissionForge::PermissionSet.connection
        return unless connection.adapter_name.match?(/mysql|trilogy/i)

        connection.execute("ALTER TABLE #{connection.quote_table_name(PermissionForge::PermissionSet.table_name)} AUTO_INCREMENT = 1")
      end

      test 'under :id a value that only starts with the id names nothing' do
        @config.api_record_identifier = :id

        get "#{BASE}/permission_sets/#{@set.id}"
        assert_response :ok

        ["#{@set.id}abc", "#{@set.id}-#{SecureRandom.hex(4)}", " #{@set.id}", "0#{@set.id}", '0x1'].each do |value|
          get "#{BASE}/permission_sets/#{CGI.escape(value)}"
          assert_response :not_found, "#{value.inspect} must not name permission set #{@set.id}"
        end
      end

      test 'under :id a uuid that starts with digits does not find the record with that number' do
        @config.api_record_identifier = :id
        uuid = "#{@set.id}#{SecureRandom.uuid[1..]}"

        get "#{BASE}/permission_sets/#{uuid}"

        assert_response :not_found
      end

      test 'nested lookups refuse the same values' do
        @config.api_record_identifier = :id

        get "#{BASE}/permission_sets/#{@set.id}/resources/#{@resource.id}"
        assert_response :ok

        get "#{BASE}/permission_sets/#{@set.id}abc/resources/#{@resource.id}"
        assert_response :not_found

        get "#{BASE}/permission_sets/#{@set.id}/resources/#{@resource.id}abc"
        assert_response :not_found
      end

      test 'under :id every bigint id is found, and one past the largest is a 404' do
        @config.api_record_identifier = :id
        largest = 9_223_372_036_854_775_807
        @auto_increment_moved = true
        [10**18, largest].each do |id|
          set = create_permission_set(name: "Set #{id}")
          set.class.where(id: set.id).update_all(id: id)

          get "#{BASE}/permission_sets/#{id}"
          assert_response :ok, "id #{id} (#{id.to_s.size} digits) must be found"
        end

        get "#{BASE}/permission_sets/#{largest + 1}"
        assert_response :not_found
      end

      test 'a NUL byte names nothing, under :uuid and under :id' do
        get "#{BASE}/permission_sets/#{@set.uuid}%00"
        assert_response :not_found

        @config.api_record_identifier = :id
        get "#{BASE}/permission_sets/#{@set.id}%00"
        assert_response :not_found
      end

      test 'under :uuid the uuid still finds the record' do
        get "#{BASE}/permission_sets/#{@set.uuid}"

        assert_response :ok
        assert_equal @set.uuid, JSON.parse(response.body).dig('data', 'uuid')
      end
    end
  end
end
