# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Admin
    class EditableLockTest < ActiveSupport::TestCase
      setup do
        @set = create_permission_set
        @resource = create_resource(permission_set: @set)
        @field = create_resource_field(resource: @resource, name: 'email')
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        @group = create_permission_set_group
      end

      test 'the chain walks up to the permission set, never to the set group' do
        @set.update!(permission_set_group: @group)

        assert_equal [@field, @resource, @set], EditableLock.chain(@field)
        assert_equal [@rule, @resource, @set], EditableLock.chain(@rule)
        assert_equal [@set], EditableLock.chain(@set)
        assert_equal [], EditableLock.chain(nil)
      end

      test 'a new child of a locked parent is locked' do
        @set.update!(is_editable: false)

        assert_equal @set, EditableLock.locked_record(@resource.resource_fields.build(name: 'phone'))
        assert_equal @set, EditableLock.locked_record(nil, [@field])
        assert_nil EditableLock.locked_record(create_permission_set)
      end

      test 'a group move is locked when either group is' do
        other = create_permission_set_group(name: 'Other')
        @group.update!(is_editable: false)

        assert_equal @group, EditableLock.locked_group_for_move(from: nil, to: @group.id.to_s)
        assert_equal @group, EditableLock.locked_group_for_move(from: @group.id, to: '')
        assert_equal @group, EditableLock.locked_group_for_move(from: @group.id, to: { 'x' => 1 })
        assert_nil EditableLock.locked_group_for_move(from: @group.id, to: @group.id.to_s)
        assert_nil EditableLock.locked_group_for_move(from: nil, to: other.id)
      end

      test 'expiry_direction compares at the column precision (microseconds)' do
        day = Time.zone.parse('2026-10-20').end_of_day # nanoseconds: .999999999
        stored = day.floor(6) # what the column keeps: .999999

        assert_equal 0, EditableLock.expiry_direction(from: stored, to: day)
        assert_equal 1, EditableLock.expiry_direction(from: stored, to: day + 1.second)
        assert_equal 1, EditableLock.expiry_direction(from: stored, to: nil)
        assert_equal(-1, EditableLock.expiry_direction(from: nil, to: day))
        assert_equal(-1, EditableLock.expiry_direction(from: stored, to: day - 1.day))
        assert_equal 0, EditableLock.expiry_direction(from: nil, to: nil)
      end

      # WEB-N1: a granting set gives its holders access, a muting set takes
      # it away — the same change to the holders goes the other way.
      test 'widens_access? depends on whether the set mutes' do
        muting = create_permission_set(name: 'Mute', is_muting: true)
        later = { from: 1.day.from_now, to: 30.days.from_now }
        earlier = { from: 30.days.from_now, to: 1.day.from_now }

        assert EditableLock.widens_access?(@set, :grant)
        assert_not EditableLock.widens_access?(@set, :revoke)
        assert EditableLock.widens_access?(@set, :change_expiry, **later)
        assert_not EditableLock.widens_access?(@set, :change_expiry, **earlier)

        assert_not EditableLock.widens_access?(muting, :grant)
        assert EditableLock.widens_access?(muting, :revoke)
        assert_not EditableLock.widens_access?(muting, :change_expiry, **later)
        assert EditableLock.widens_access?(muting, :change_expiry, **earlier)
        assert_not EditableLock.widens_access?(muting, :change_expiry, from: 1.day.from_now, to: nil) # cleared: narrows
        assert_not EditableLock.widens_access?(muting, :change_expiry, from: nil, to: nil)
        assert_raises(KeyError) { EditableLock.widens_access?(@set, :unknown) }
      end

      test 'widening_lock names the locked set only for a widening change' do
        muting = create_permission_set(name: 'Mute', is_muting: true, is_editable: false)
        @set.update!(is_editable: false)

        assert_equal @set, EditableLock.widening_lock(@set, :grant)
        assert_nil EditableLock.widening_lock(@set, :revoke)
        assert_equal muting, EditableLock.widening_lock(muting, :revoke)
        assert_nil EditableLock.widening_lock(muting, :grant)
        assert_nil EditableLock.widening_lock(create_permission_set(name: 'Open', is_muting: true), :revoke)
      end

      test 'ChangeSet skips a move into a locked group' do
        @group.update!(is_editable: false)

        changes = ChangeSet.new(permission_set: @set, params: { set: { permission_set_group_id: @group.id.to_s, name: 'Renamed' } }).apply!

        assert_equal %w[name], changes.map(&:attribute)
        assert_nil @set.reload.permission_set_group_id
      end
    end
  end
end
