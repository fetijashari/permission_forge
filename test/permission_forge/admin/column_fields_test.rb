require 'test_helper'

module PermissionForge
  module Admin
    # The admin's presets, "Add all new" and "Sync fields" create rows through
    # ColumnFields; Rails' timestamps there follow TimestampFields, as in
    # ResourceFieldGenerator: at most Read-only on a granting set.
    class ColumnFieldsTest < ActiveSupport::TestCase
      TIMESTAMPS = %w[created_at updated_at].freeze

      def rows(level, muting: false)
        set = create_permission_set(name: "Columns #{level} #{muting}", is_muting: muting)
        resource = create_resource(permission_set: set, name: 'Customer', read_access: !muting, edit_access: !muting)
        ColumnFields.new(resource, muting: muting).create(%w[domain] + TIMESTAMPS, level)
        resource.resource_fields.reload.index_by(&:name)
      end

      def level(field, muting: false)
        FieldLevel.level_of(field, muting: muting)
      end

      test 'a level that grants read gives the timestamps Read-only, never Editable or Masked' do
        { 'edit' => 'edit', 'read' => 'read', 'masked' => 'masked' }.each do |chosen, domain_level|
          fields = rows(chosen)

          assert_equal domain_level, level(fields['domain']), chosen
          TIMESTAMPS.each { |name| assert_equal 'read', level(fields[name]), "#{name} at #{chosen}" }
        end
      end

      test 'Hidden leaves the timestamps hidden' do
        fields = rows('hidden')

        assert_equal(%w[hidden hidden hidden], (%w[domain] + TIMESTAMPS).map { |name| level(fields[name]) })
      end

      test 'a Muting Permission Set gets the level it asked for on the timestamps too' do
        { 'hide' => 'hide', 'mask' => 'mask' }.each do |chosen, expected|
          fields = rows(chosen, muting: true)

          TIMESTAMPS.each { |name| assert_equal expected, level(fields[name], muting: true), "#{name} at #{chosen}" }
        end
      end

      test 'a resource whose model does not load creates the rows at the level' do
        resource = create_resource(permission_set: create_permission_set, name: 'PfNoSuchModel', edit_access: true)
        ColumnFields.new(resource, muting: false).create(%w[created_at], 'edit')

        assert_equal 'edit', level(resource.resource_fields.find_by!(name: 'created_at'))
      end
    end
  end
end
