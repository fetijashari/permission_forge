# frozen_string_literal: true

require_relative 'admin_test_case'

module PermissionForge
  module Html
    # What an admin page costs in schema metadata. Every page draws the
    # navigation, whose attention count lists the unconfigured personal-data
    # columns of each readable model: that read is the schema cache's
    # (Admin::ModelCatalog.new(verify: false)), never the database. The rule
    # builder compares the target model's columns with the database once per
    # render (its column list builds the form), however often the template
    # asks for the options.
    class AdminMetadataQueriesTest < AdminTestCase
      METADATA = Regexp.union(/\APRAGMA\s+(?:table_x?info|index_list|foreign_key_list)/i, /pg_attribute/i,
                              /information_schema\.columns/i, /SHOW\s+(?:FULL\s+)?(?:FIELDS|COLUMNS)/i)

      setup do
        @admin = create_permission_set(name: 'Admin')
        create_permission_set_user(user: @bo, permission_set: @admin)
        PermissionForge.configuration.unconfigured_field_strategy = :pass_through # the attention items read every model's columns
        @set = create_permission_set(name: 'Readers')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_resource(permission_set: @set, name: 'Supplier', read_access: true)
      end

      # Metadata queries `path` costs on a warm schema cache.
      def metadata_queries(path)
        get pf(path)
        assert_response :success
        queries = []
        subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
          queries << payload[:sql] if payload[:sql].to_s.match?(METADATA)
        end
        get pf(path)
        assert_response :success
        queries
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end

      test 'a page that only draws the navigation reads no column list from the database' do
        assert_not_empty PermissionForge::Admin::AttentionItems.new.privacy_findings, 'the navigation counts Customer columns'
        %w[/ /permission_sets /people].each do |path|
          assert_equal [], metadata_queries(path), path
        end
      end

      test 'the rule builder compares the target model with the database once per render' do
        queries = metadata_queries("/permission_sets/#{@set.id}/resources/Customer/rules/new")

        assert_operator queries.size, :<=, 1, queries.inspect
      end
    end
  end
end
