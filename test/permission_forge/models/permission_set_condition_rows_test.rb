# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # The activation conditions as a PermissionSet row holds them: one parser
  # (ActivationConditions: #allowed_ip_list, #hours_window), checked when
  # the row is new or the condition changes, normalised on save, and read
  # the same by Ruby (#conditional?) and SQL (.conditional / .unconditional).
  class PermissionSetConditionRowsTest < ActiveSupport::TestCase
    def set(**attrs)
      PermissionForge::PermissionSet.new(uuid: SecureRandom.uuid, name: PermissionForge::PermissionSet.unique_name('Cond'), **attrs)
    end

    def errors_on(column, **attrs)
      row = set(**attrs)
      row.valid?
      row.errors[column]
    end

    # --- the IP list ---------------------------------------------------------

    test 'allowed_ip_list splits on commas, newlines and spaces and drops blanks' do
      assert_equal %w[10.0.0.0/8 192.168.0.0/16 203.0.113.9],
                   set(allowed_ips: "10.0.0.0/8\n192.168.0.0/16 ,, 203.0.113.9 ").allowed_ip_list
      assert_equal [], set(allowed_ips: nil).allowed_ip_list
      assert_equal [], set(allowed_ips: ' , ').allowed_ip_list
    end

    test 'a new row with an entry that is not an IP or a CIDR is refused, naming the entry' do
      assert_equal [I18n.t('permission_forge.validations.permission_set.invalid_ip_entry', entry: 'office')],
                   errors_on(:allowed_ips, allowed_ips: '10.0.0.0/8, office')
      assert_empty errors_on(:allowed_ips, allowed_ips: "10.0.0.0/8\n192.168.0.0/16")
      assert_empty errors_on(:allowed_ips, allowed_ips: '2001:db8::/32, 203.0.113.9')
    end

    test 'the stored list is normalised to commas on save' do
      row = create_permission_set(allowed_ips: "10.0.0.0/8\n 192.168.0.0/16")

      assert_equal '10.0.0.0/8,192.168.0.0/16', row.reload.allowed_ips
      assert_nil create_permission_set(allowed_ips: ' , ').reload.allowed_ips, 'separators alone are no condition'
    end

    test 'a legacy row with a broken list stays editable until the list changes' do
      row = create_permission_set(allowed_ips: '10.0.0.0/8')
      row.update_columns(allowed_ips: 'office')

      row.reload
      assert row.update(description: 'still editable')
      assert_not row.update(allowed_ips: 'office, 10.0.0.0/8'), 'a changed list is checked'
      assert row.update(allowed_ips: '10.0.0.0/8')
    end

    # --- the hour window -------------------------------------------------------

    test 'hours_window: none, a window, an overnight window, and the broken shapes' do
      assert_not set.hours_window.set?
      assert_not set.hours_window.broken?

      window = set(allowed_hours_start: 9, allowed_hours_end: 17).hours_window
      assert window.set?
      assert_not window.broken?
      assert_not window.wraps?
      assert window.include?(9)
      assert_not window.include?(17)

      overnight = set(allowed_hours_start: 22, allowed_hours_end: 6).hours_window
      assert overnight.wraps?
      assert overnight.include?(23)
      assert overnight.include?(5)
      assert_not overnight.include?(12)

      [[9, 9], [9, nil], [nil, 9], [25, 3], [9, -1]].each do |from, to|
        broken = set(allowed_hours_start: from, allowed_hours_end: to).hours_window
        assert broken.set?, [from, to].inspect
        assert broken.broken?, [from, to].inspect
        assert_not broken.include?(9), "#{[from, to].inspect} includes no hour"
      end
    end

    test 'a new row with the same start and end hour is refused' do
      assert_equal [I18n.t('permission_forge.validations.permission_set.hours_equal')],
                   errors_on(:allowed_hours_end, allowed_hours_start: 22, allowed_hours_end: 22)
    end

    test 'a new row with one hour of the two is refused on the missing one' do
      assert_equal [I18n.t('permission_forge.validations.permission_set.hours_incomplete')],
                   errors_on(:allowed_hours_end, allowed_hours_start: 9)
      assert_equal [I18n.t('permission_forge.validations.permission_set.hours_incomplete')],
                   errors_on(:allowed_hours_start, allowed_hours_end: 17)
      assert_empty errors_on(:allowed_hours_start, allowed_hours_start: 0, allowed_hours_end: 23)
    end

    test 'a legacy row with one hour stays editable until an hour changes' do
      row = create_permission_set(allowed_hours_start: 9, allowed_hours_end: 17)
      row.update_columns(allowed_hours_end: nil)

      row.reload
      assert row.update(description: 'still editable')
      assert_not row.update(allowed_hours_start: 10), 'a changed hour is checked with the other'
      assert row.update(allowed_hours_start: 10, allowed_hours_end: 18)
    end

    # --- what the row says about itself -----------------------------------------

    test 'condition_problems names what the validation refuses, for a stored row too' do
      assert_empty set(allowed_ips: '10.0.0.0/8', allowed_hours_start: 9, allowed_hours_end: 17).condition_problems

      row = create_permission_set(allowed_ips: '10.0.0.0/8')
      row.update_columns(allowed_ips: 'office, 10.0.0.0/8', allowed_hours_start: 9, allowed_hours_end: 9)

      assert_equal %i[ip_entry hours_equal], row.reload.condition_problems.map(&:first)
      assert_equal %i[hours_incomplete], set(allowed_hours_end: 9).condition_problems.map(&:first)
      assert_equal %i[hours_range], set(allowed_hours_start: 25, allowed_hours_end: 3).condition_problems.map(&:first)
      assert row.conditions_broken?
    end

    test 'conditional? and the SQL scopes agree: whitespace is no condition, one hour of the two is' do
      blank = create_permission_set(name: 'Blank')
      blank.update_columns(allowed_ips: '   ', requires_session_flag: ' ')
      half = create_permission_set(name: 'Half')
      half.update_columns(allowed_hours_end: 9)

      assert_not blank.reload.conditional?
      assert half.reload.conditional?
      assert_includes PermissionForge::PermissionSet.unconditional, blank
      assert_not_includes PermissionForge::PermissionSet.conditional, blank
      assert_includes PermissionForge::PermissionSet.conditional, half
      assert_not_includes PermissionForge::PermissionSet.unconditional, half
    end
  end
end
