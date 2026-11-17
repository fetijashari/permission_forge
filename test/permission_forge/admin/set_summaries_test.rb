require 'test_helper'

module PermissionForge
  module Admin
    # The Permission Sets list's counts (Admin::SetSummaries): what each
    # set's Resources allow and what narrows them, read from tuples, every
    # count from the one definition it counts.
    class SetSummariesTest < ActiveSupport::TestCase
      FLAGS = SetSummaries::FLAGS

      setup do
        @set = create_permission_set(name: 'Warehouse staff')
      end

      def summary(set = @set) = SetSummaries.call([set.reload]).fetch(set.id)

      # A Resource row as stored, past the validations (a row written by an
      # older version, the console or raw SQL).
      def stored_resource(name, set: @set, **flags)
        resource = create_resource(permission_set: set, name: name, read_access: false)
        resource.update_columns(FLAGS.index_with(false).merge(flags))
        resource
      end

      test 'every granting flag combination is counted as PermissionHashBuilder.granted_flags grants it' do
        combos = [true, false].repeated_permutation(FLAGS.size).map { |values| FLAGS.zip(values).to_h }
        rows = combos.each_with_index.map { |flags, index| stored_resource("Warehouses::Bin#{index}", **flags) }

        entries = SetSummaries.entries([@set.reload]).index_by(&:id)
        rows.each do |row|
          assert_equal Services::PermissionHashBuilder.granted_flags(row.reload), entries.fetch(row.id).flags,
                       "flags of #{row.attributes.slice(*FLAGS.map(&:to_s))}"
        end
        expected = FLAGS.index_with { |flag| rows.count { |row| Services::PermissionHashBuilder.granted_flags(row)[flag] } }
        assert_equal expected, summary.flags
      end

      test 'edit or delete without read, and Modify All without View All, count for nothing' do
        stored_resource('Warehouse', edit_access: true, delete_access: true, modify_all: true)

        flags = summary.flags
        assert_equal 0, flags[:edit_access]
        assert_equal 0, flags[:delete_access]
        assert_equal 0, flags[:modify_all]
        assert_equal 'none', summary.profile
      end

      test 'a muting set counts what it takes away, as stored' do
        muting = create_permission_set(name: 'No deletes', is_muting: true)
        stored_resource('Warehouse', set: muting, delete_access: true, modify_all: true)

        result = summary(muting)
        assert_equal 1, result.flags[:delete_access]
        assert_equal 1, result.flags[:modify_all]
        assert_equal 'takes_away', result.profile
      end

      test 'a turned-off Resource is counted apart and grants nothing' do
        create_resource(permission_set: @set, name: 'Warehouse', read_access: true)
        create_resource(permission_set: @set, name: 'Ledger', read_access: true, is_active: false)

        result = summary
        assert_equal 1, result.resources
        assert_equal 1, result.inactive
        assert_equal 1, result.flags[:read_access]
      end

      test 'the profile names the widest access the set allows' do
        create_resource(permission_set: @set, name: 'Warehouse', read_access: true)
        assert_equal 'read_only', summary.profile

        create_resource(permission_set: @set, name: 'Ledger', read_access: true, edit_access: true)
        assert_equal 'mixed', summary.profile

        @set.resources.each { |resource| resource.update!(create_access: true, edit_access: true, delete_access: true) }
        assert_equal 'full', summary.profile

        assert_equal 'none', summary(create_permission_set(name: 'Empty')).profile
      end

      test 'row rules: active ones count, a rule View All bypasses is ignored, a muting set adds none' do
        filtered = create_resource(permission_set: @set, name: 'Warehouse', read_access: true)
        bypassed = create_resource(permission_set: @set, name: 'Ledger', read_access: true, view_all: true)
        create_permission_set_rule(permission_set: @set, resource: filtered, field_name: 'name', field_value: 'x')
        create_permission_set_rule(permission_set: @set, resource: filtered, field_name: 'name', field_value: 'y',
                                   is_active: false)
        create_permission_set_rule(permission_set: @set, resource: bypassed, field_name: 'name', field_value: 'z')

        result = summary
        assert_equal 1, result.rules
        assert_equal 1, result.rule_resources
        assert_equal 1, result.ignored_rules
        assert_not result.every_row?

        entries = result.entries.index_by(&:name)
        assert entries.fetch('Warehouse').narrowed?
        assert_not entries.fetch('Ledger').narrowed?, 'a rule View All bypasses narrows nothing'
      end

      test 'masked fields follow FieldLevel: read and mask on, active; a muting set counts force-masked and hidden' do
        resource = create_resource(permission_set: @set, name: 'Warehouse', read_access: true)
        create_resource_field(resource: resource, name: 'email', read_access: true, mask_access: true)
        create_resource_field(resource: resource, name: 'phone', read_access: true, mask_access: true, is_active: false)
        hidden = create_resource_field(resource: resource, name: 'iban', read_access: true)
        hidden.update_columns(read_access: false, mask_access: true) # Hidden: a mask on a field nobody reads
        create_resource_field(resource: resource, name: 'city', read_access: true)

        result = summary
        assert_equal 1, result.masked
        assert_equal 1, result.masked_resources

        muting = create_permission_set(name: 'Contractors', is_muting: true)
        muted = create_resource(permission_set: muting, name: 'Warehouse', read_access: false)
        create_resource_field(resource: muted, name: 'email', read_access: false, mask_access: true)
        create_resource_field(resource: muted, name: 'phone', read_access: true)
        create_resource_field(resource: muted, name: 'city', read_access: false)

        result = summary(muting)
        assert_equal 1, result.masked
        assert_equal 1, result.hidden
        assert_equal 1, result.hidden_resources
      end

      test 'View All on every Resource sees every row' do
        create_resource(permission_set: @set, name: 'Warehouse', read_access: true, view_all: true)
        assert summary.every_row?

        create_resource(permission_set: @set, name: 'Ledger', read_access: true)
        assert_not summary.every_row?
      end

      test 'the counts take three queries, whatever the number of sets and rows' do
        small = queries_for([@set.reload])
        sets = Array.new(4) do |index|
          set = create_permission_set(name: "Team #{index}")
          3.times do |n|
            resource = create_resource(permission_set: set, name: "Warehouses::Bin#{n}", read_access: true)
            create_resource_field(resource: resource, name: 'email', read_access: true, mask_access: true)
            create_permission_set_rule(permission_set: set, resource: resource, field_name: 'name', field_value: 'x')
          end
          set
        end

        assert_equal 1, small, 'a set without Resources reads nothing else'
        assert_equal 3, queries_for(sets)
      end

      test 'a search matches the stored name of an active Resource, in any case' do
        create_resource(permission_set: @set, name: 'Warehouses::Bin', read_access: true)
        create_resource(permission_set: @set, name: 'Ledger', read_access: true, is_active: false)

        assert_equal ['Warehouses::Bin'], summary.matching('bin').map(&:name)
        assert_empty summary.matching('ledger')
      end

      private

      def queries_for(sets)
        count = 0
        counter = ->(*, payload) { count += 1 unless payload[:name] == 'SCHEMA' || payload[:sql].start_with?('PRAGMA') }
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { SetSummaries.call(sets) }
        count
      end
    end
  end
end
