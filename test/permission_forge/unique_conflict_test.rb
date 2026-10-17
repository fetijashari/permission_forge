# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # UniqueConflict names the validation error a uniqueness race would have
  # shown, from the index the adapter's RecordNotUnique names. The first
  # test enumerates: every unique index of the nine tables, but a table's
  # uuid index, must be backed by a uniqueness validation it can name — a
  # new unique index without one (its race would be answered with the
  # generic message only) fails here by table and columns.
  class UniqueConflictTest < ActiveSupport::TestCase
    UUID_INDEX = %w[uuid].freeze

    test 'every unique index of the nine tables, but the uuid indexes, is backed by a uniqueness validation' do
      missing = PermissionForge::TestModels.all.flat_map do |model|
        unique_indexes(model).reject { |index| Array(index.columns).map(&:to_s) == UUID_INDEX }
                             .reject { |index| UniqueConflict.conflict_for(model, index) }
                             .map { |index| "#{model.table_name}(#{Array(index.columns).join(', ')})" }
      end
      assert_empty missing, 'unique indexes no uniqueness validation answers for: add the validation (or its scope)'
      assert_operator PermissionForge::TestModels.all.sum { |model| unique_indexes(model).size }, :>=, 4,
                      'the dummy schema lost its unique indexes'
    end

    test 'the real error of each indexed table is answered with the message its validation gives' do
      set = create_permission_set(name: 'Sales')
      group = create_permission_set_group(name: 'Team')
      user = create_user
      resource = create_resource(permission_set: set, name: 'Customer')
      create_resource_field(resource: resource, name: 'email')
      create_permission_set_user(user: user, permission_set: set)
      PermissionForge::PermissionSetGroupUser.create!(permission_set_group: group, user: user)

      twins = [
        PermissionForge::Resource.new(permission_set: set, name: 'Customer'),
        PermissionForge::ResourceField.new(resource: resource, name: 'email', label: 'E'),
        PermissionForge::PermissionSetUser.new(permission_set: set, user: user),
        PermissionForge::PermissionSetGroupUser.new(permission_set_group: group, user: user)
      ]
      twins.each do |twin|
        twin.validate
        expected = twin.errors.messages
        assert_not_empty expected, "#{twin.class} has no uniqueness validation"

        error = assert_raises(ActiveRecord::RecordNotUnique, twin.class.name) { twin.save!(validate: false) }
        assert_equal expected, UniqueConflict.messages(error), twin.class.name
        assert_equal PermissionForge::Admin::ErrorSentence.first(twin.errors), UniqueConflict.sentence(error), twin.class.name
        assert_not_includes UniqueConflict.sentence(error), 'User ', 'the attribute is named by the gem (Person), not by human_attribute_name'
      end
    end

    test 'an index named as PostgreSQL and MySQL word it is found by its name' do
      index = unique_indexes(PermissionForge::PermissionSetUser).find { |candidate| Array(candidate.columns).include?('user_id') }
      [
        "PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint \"#{index.name}\"\n" \
        'DETAIL:  Key (permission_set_id, user_id)=(1, 2) already exists.',
        "Mysql2::Error: Duplicate entry '1-2' for key 'permission_set_users.#{index.name}'"
      ].each do |message|
        messages = UniqueConflict.messages(ActiveRecord::RecordNotUnique.new(message))
        assert_equal [:user_id], messages&.keys, message
        assert_not_empty messages[:user_id].first
      end
    end

    test 'an error naming no known index, or nothing at all, names no conflict' do
      ['UNIQUE constraint failed: audit_events.uuid',
       'PG::UniqueViolation: duplicate key value violates unique constraint "index_users_on_email"',
       '', 'Mysql2::Error: Duplicate entry'].each do |message|
        error = ActiveRecord::RecordNotUnique.new(message)
        assert_nil UniqueConflict.messages(error), message.inspect
        assert_nil UniqueConflict.sentence(error), message.inspect
      end
    end

    test 'a table that cannot be read names no conflict' do
      model = PermissionForge::AuditEvent
      original = model.method(:table_name).unbind
      replace_singleton_method(model, :table_name) { 'no_such_table' }
      assert_nil UniqueConflict.messages(ActiveRecord::RecordNotUnique.new('UNIQUE constraint failed: no_such_table.uuid'))
    ensure
      replace_singleton_method(model, :table_name, original)
    end

    private

    def unique_indexes(model)
      model.connection_pool.with_connection { |connection| connection.indexes(model.table_name) }.select(&:unique)
    end
  end
end
