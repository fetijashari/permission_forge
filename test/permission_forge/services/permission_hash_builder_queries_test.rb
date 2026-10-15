# frozen_string_literal: true

require 'test_helper'
require_relative '../field_variant_models'

module PermissionForge
  module Services
    # A permission-hash rebuild reads every row it needs in a fixed number of
    # queries, whatever the number of sets, resources, fields, actions and
    # rules: each holder of a set rebuilds read-through after any edit to it,
    # and the per-resource queries of 0.13 (828 for 10 sets x 20 resources)
    # turned one save into a thundering herd (pre-release performance review MAJOR-1).
    class PermissionHashBuilderQueriesTest < ActiveSupport::TestCase
      # What a rebuild may cost: the assignments and sets, resources, fields,
      # actions, rules, the user's assignment rows, the soonest expiry — and
      # the two grantor lookups when assignments are stamped.
      MAX_QUERIES = 10

      PERMISSION_TABLES = %w[permission_sets resources resource_fields resource_actions permission_set_rules].freeze

      # The table a query reads, however the adapter quotes it: "t" (SQLite,
      # PostgreSQL) or `t` (MySQL).
      FROM_TABLE = /FROM\s+["`]?(\w+)["`]?/i

      test 'a rebuild runs the same queries for one set as for many' do
        small = holder_of(sets: 1, resources: 1, fields: 2)
        large = holder_of(sets: 4, resources: 5, fields: 6, actions: 2, rules: 2, muting: 1)

        small_queries = rebuild_queries(small)
        large_queries = rebuild_queries(large)

        assert_operator large_queries.size, :<=, MAX_QUERIES, large_queries.join("\n")
        assert_equal small_queries.size, large_queries.size, large_queries.join("\n")
      end

      test 'each permission table is read once per rebuild' do
        user = holder_of(sets: 3, resources: 4, fields: 3, actions: 1, rules: 1, muting: 1)

        reads = rebuild_queries(user).group_by { |sql| sql[FROM_TABLE, 1] }.transform_values(&:size)

        PERMISSION_TABLES.each { |table| assert_equal 1, reads[table], "#{table}: #{reads.inspect}" }
        assert_operator reads['permission_set_users'], :<=, 3, reads.inspect
      end

      test 'the grantors of stamped assignments are looked up once, not per resource' do
        PermissionForge.configuration.audit_trail_enabled = true
        admin = create_user(name: 'Ada Admin')
        user = holder_of(sets: 3, resources: 4, fields: 2, assignment: { created_by_id: admin.id, updated_by_id: admin.id })

        queries = rebuild_queries(user)
        hash = User.find(user.id).permissions_hash

        assert_operator queries.size, :<=, MAX_QUERIES, queries.join("\n")
        assert_operator queries.count { |sql| sql.scan(FROM_TABLE).flatten.include?('users') }, :<=, 2, queries.join("\n")
        sources = hash.dig(:permissions, :resources).values.flat_map { |entry| entry[:source_permission_sets] }
        assert_equal [admin.uuid], sources.map { |source| source[:permission_set_granted_by] }.uniq
      end

      # Preloading builds the user model's scope (its default scopes run, an
      # auto-scoped model reports a bypass) even for no id; the association
      # readers before it never did.
      test 'assignments nobody stamped leave the user model alone' do
        user = holder_of(sets: 2, resources: 1, fields: 1)
        built = 0
        User.define_singleton_method(:scope_for_association) do |*args, **options|
          built += 1
          super(*args, **options)
        end

        rebuild_queries(user)

        assert_equal 0, built
      ensure
        User.singleton_class.send(:remove_method, :scope_for_association)
      end

      test 'inactive rows read in bulk are left out as the active scope left them out' do
        user = holder_of(sets: 1, resources: 2, fields: 2, actions: 1, rules: 1)
        set = PermissionForge::PermissionSet.find_by!(name: 'Holder set 0')
        off_resource = set.resources.order(:id).first
        on_resource = set.resources.order(:id).last
        off_resource.update!(is_active: false)
        on_resource.resource_fields.order(:id).first.update!(is_active: false)
        on_resource.resource_actions.first.update!(is_active: false)
        on_resource.permission_set_rules.first.update!(is_active: false)

        entries = User.find(user.id).permissions_hash.dig(:permissions, :resources)

        assert_equal [on_resource.name.to_sym], entries.keys
        entry = entries[on_resource.name.to_sym]
        assert_equal %w[field_1], entry[:fields].keys.map(&:to_s)
        assert_empty entry[:actions]
        assert_empty entry[:permission_set_rules]
      end

      # The database returns rows in whatever order its plan gives; the first
      # row of a name decides a tie (two fields mapping to one variant:
      # "first mask_strategy wins"), and rules and actions keep their order.
      test 'the hash does not depend on the order the rows come back in' do
        user = create_user
        set = create_permission_set
        create_permission_set_user(user: user, permission_set: set)
        resource = create_resource(permission_set: set, name: 'PfVariantOrder', read_access: true)
        create_resource_field(resource: resource, name: 'owner_id', mask_access: true, mask_strategy: 'last4')
        create_resource_field(resource: resource, name: 'owner_uuid', mask_access: true, mask_strategy: 'email')
        2.times { |i| create_permission_set_rule(permission_set: set, resource: resource, name: "rule #{i}") }
        2.times { |i| create_resource_action(resource: resource, name: "action_#{i}") }

        expected = build_for(user, set)
        reversed = PermissionForge::PermissionSet.where(id: set.id).to_a
        ActiveRecord::Associations::Preloader.new(records: reversed, associations: { resources: PermissionHashBuilder::RESOURCE_ROWS }).call
        reversed.each do |loaded|
          loaded.association(:resources).target.each do |row|
            PermissionHashBuilder::RESOURCE_ROWS.each { |name| row.association(name).target.reverse! }
          end
        end

        assert_equal expected, PermissionHashBuilder.call(user: user, permission_sets: reversed)
        assert_equal 'last4', expected.dig(:resources, 'PfVariantOrder', :fields, 'owner_uuid', :mask_strategy), 'the older row wins'
      end

      private

      def build_for(user, set)
        PermissionHashBuilder.call(user: user, permission_sets: PermissionForge::PermissionSet.where(id: set.id).to_a)
      end

      # A user holding `sets` granting sets of `resources` resources each,
      # and `rows[:muting]` muting sets; `rows[:assignment]` goes on every
      # assignment.
      def holder_of(sets:, resources:, fields:, **rows)
        user = create_user
        actions, rules = rows.values_at(:actions, :rules).map(&:to_i)
        sets.times do |index|
          set = holder_set(user, "Holder set #{index}", rows)
          resources.times { |number| fill_resource(set, "PfQueryRes#{number}", fields, actions, rules) }
        end
        rows[:muting].to_i.times do |index|
          fill_resource(holder_set(user, "Holder muting #{index}", rows, is_muting: true), 'PfQueryRes0', fields, actions, 0)
        end
        user
      end

      def holder_set(user, name, rows, **attrs)
        set = create_permission_set(name: PermissionForge::PermissionSet.unique_name(name), **attrs)
        create_permission_set_user(user: user, permission_set: set, **rows[:assignment].to_h)
        set
      end

      def fill_resource(set, name, fields, actions, rules)
        resource = create_resource(permission_set: set, name: name, read_access: true, edit_access: true)
        fields.times { |index| create_resource_field(resource: resource, name: "field_#{index}") }
        actions.times { |index| create_resource_action(resource: resource, name: "action_#{index}", is_permitted: true) }
        rules.times do |index|
          create_permission_set_rule(permission_set: set, resource: resource, field_name: 'domain', field_value: "v#{index}")
        end
      end

      # The SQL a cold rebuild of the user's hash runs (the user is loaded first).
      def rebuild_queries(user)
        user = User.find(user.id)
        PermissionForge.cache.clear
        queries = []
        callback = lambda do |*, payload|
          queries << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached]
        end
        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { user.regenerate_permissions }
        queries
      end
    end
  end
end
