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

      # "Locked" has one definition, the chain: a view's pf_locked? and a controller's refusal agree.
      test 'locked? walks the chain; flagged? is the record alone' do
        @set.update!(is_editable: false)

        assert EditableLock.locked?(@field)
        assert EditableLock.locked?(@rule)
        assert EditableLock.locked?(@resource.resource_fields.build(name: 'phone'))
        assert_not EditableLock.flagged?(@field)
        assert EditableLock.flagged?(@set)
        assert_not EditableLock.locked?(nil)
        assert_not EditableLock.locked?(create_permission_set)
      end

      # The one table the controllers' refusals and the views' "show or disable" read.
      test 'permits? refuses what changes a locked record, lets a copy, a review and narrowing through' do
        assignment = create_permission_set_user(user: create_user, permission_set: @set)
        assert EditableLock.permits?(@field, :edit)
        @set.update!(is_editable: false)

        %i[edit add toggle sync acknowledge apply_recommendation].each do |action|
          assert_not EditableLock.permits?(@field, action), action
          assert_not EditableLock.permits?(@resource, action), action
        end
        assert_not EditableLock.permits?(@rule, :delete)
        assert EditableLock.permits?(@set, :duplicate)
        assert EditableLock.permits?(assignment, :review)
        assert EditableLock.permits?(assignment, :revoke), 'removing a holder of a granting set narrows'
        assert_not EditableLock.permits?(assignment, :grant)
        assert_not EditableLock.permits?(@set, :grant)
        assert EditableLock.permits?(assignment, :change_expiry, from: nil, to: 1.day.from_now), 'setting an end date narrows'
        assert_not EditableLock.permits?(assignment, :change_expiry, from: 1.day.from_now, to: nil)
      end

      test 'permits? flips the holder direction for a Muting Permission Set and asks the container for :delete' do
        muting = create_permission_set(name: 'No exports', is_muting: true, is_editable: false)
        held = create_permission_set_user(user: create_user, permission_set: muting)

        assert EditableLock.permits?(muting, :grant)
        assert_not EditableLock.permits?(held, :revoke)
        assert EditableLock.permits?(held, :change_expiry, from: 1.day.from_now, to: nil), 'keeping a holder longer narrows'

        @set.update!(permission_set_group: @group)
        assert EditableLock.permits?(@set, :delete)
        @group.update!(is_editable: false)

        assert_not EditableLock.permits?(@set, :delete), 'deleting changes the locked group\'s list of sets'
        assert EditableLock.permits?(@set, :edit), 'the set itself is editable'
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

      # b-admin-ui #118: the menu offered end dates the lock then refused.
      test 'expiry_choices offers only what the lock lets through, in the set\'s direction' do
        today = Date.new(2026, 10, 15)
        user = create_user
        granting = create_permission_set_user(user: user, permission_set: @set,
                                              expires_at: (today + 14).in_time_zone.end_of_day)
        all = ExpiryPresets::CHANGE_KEYS

        assert_equal all, EditableLock.expiry_choices(granting, today: today)

        @set.update!(is_editable: false)
        assert_equal %w[1w], EditableLock.expiry_choices(granting.reload, today: today) # eom: 31 Oct, later

        muting_set = create_permission_set(name: 'Mute', is_muting: true)
        muting = create_permission_set_user(user: user, permission_set: muting_set,
                                            expires_at: (today + 14).in_time_zone.end_of_day)
        muting_set.update!(is_editable: false)
        assert_equal %w[30d eom never], EditableLock.expiry_choices(muting.reload, today: today)
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
