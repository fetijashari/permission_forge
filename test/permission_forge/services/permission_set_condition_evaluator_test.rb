require 'test_helper'

module PermissionForge
  module Services
    class PermissionSetConditionEvaluatorTest < ActiveSupport::TestCase
      # --- Unconditional sets always pass ---

      test 'unconditional set passes with empty context' do
        ps = create_permission_set
        assert evaluate(ps, {})
      end

      test 'unconditional set passes with any context' do
        ps = create_permission_set
        assert evaluate(ps, { ip: '1.2.3.4', session_flags: ['mfa'], time: Time.current })
      end

      # --- Session flag ---

      test 'session flag: passes when flag is present in context' do
        ps = create_permission_set(requires_session_flag: 'mfa_verified')
        assert evaluate(ps, { session_flags: ['mfa_verified'] })
      end

      test 'session flag: fails when flag is missing from context' do
        ps = create_permission_set(requires_session_flag: 'mfa_verified')
        assert_not evaluate(ps, { session_flags: ['other_flag'] })
      end

      test 'session flag: fails when session_flags is empty' do
        ps = create_permission_set(requires_session_flag: 'mfa_verified')
        assert_not evaluate(ps, { session_flags: [] })
      end

      test 'session flag: fails when session_flags is nil' do
        ps = create_permission_set(requires_session_flag: 'mfa_verified')
        assert_not evaluate(ps, {})
      end

      test 'session flag: passes when flag is one of multiple flags' do
        ps = create_permission_set(requires_session_flag: 'mfa_verified')
        assert evaluate(ps, { session_flags: %w[admin mfa_verified elevated] })
      end

      test 'session flag: nil condition always passes' do
        ps = create_permission_set(requires_session_flag: nil)
        assert evaluate(ps, {})
      end

      test 'session flag: blank condition always passes' do
        ps = create_permission_set(requires_session_flag: '')
        assert evaluate(ps, {})
      end

      # --- IP range ---

      test 'ip: passes when IP matches single CIDR' do
        ps = create_permission_set(allowed_ips: '192.168.1.0/24')
        assert evaluate(ps, { ip: '192.168.1.50' })
      end

      test 'ip: fails when IP outside CIDR' do
        ps = create_permission_set(allowed_ips: '192.168.1.0/24')
        assert_not evaluate(ps, { ip: '10.0.0.1' })
      end

      test 'ip: passes when IP matches one of multiple CIDRs' do
        ps = create_permission_set(allowed_ips: '192.168.1.0/24, 10.0.0.0/8')
        assert evaluate(ps, { ip: '10.5.5.5' })
      end

      test 'ip: fails when IP matches none of multiple CIDRs' do
        ps = create_permission_set(allowed_ips: '192.168.1.0/24, 10.0.0.0/8')
        assert_not evaluate(ps, { ip: '172.16.0.1' })
      end

      test 'ip: exact IP match (single host)' do
        ps = create_permission_set(allowed_ips: '203.0.113.42/32')
        assert evaluate(ps, { ip: '203.0.113.42' })
        assert_not evaluate(ps, { ip: '203.0.113.43' })
      end

      test 'ip: fails when context has no IP' do
        ps = create_permission_set(allowed_ips: '192.168.1.0/24')
        assert_not evaluate(ps, {})
      end

      test 'ip: fails gracefully with invalid context IP' do
        ps = create_permission_set(allowed_ips: '192.168.1.0/24')
        assert_not evaluate(ps, { ip: 'not-an-ip' })
      end

      test 'ip: accepts an IPAddr as the request IP' do
        ps = create_permission_set(allowed_ips: '192.168.1.0/24')
        assert evaluate(ps, { ip: IPAddr.new('192.168.1.50') })
        assert_not evaluate(ps, { ip: IPAddr.new('10.0.0.1') })
        assert_not evaluate(ps, { ip: IPAddr.new('::ffff:192.168.1.50') }), 'an IPv6 address is outside an IPv4 range'
      end

      # An entry that is not an address used to be skipped, so the set passed
      # on the entries beside it; since 0.15 such a list is refused on save
      # and, where stored anyway, never passes (nobody can judge it).
      test 'ip: an invalid CIDR is refused on save and never passes when stored' do
        assert_raises(ActiveRecord::RecordInvalid) { create_permission_set(allowed_ips: 'invalid, 192.168.1.0/24') }

        ps = stored(allowed_ips: 'invalid, 192.168.1.0/24')
        assert_not evaluate(ps, { ip: '192.168.1.5' })
      end

      test 'ip: nil condition always passes' do
        ps = create_permission_set(allowed_ips: nil)
        assert evaluate(ps, {})
      end

      test 'ip: blank condition always passes' do
        ps = create_permission_set(allowed_ips: '')
        assert evaluate(ps, {})
      end

      # --- Login hours ---

      test 'hours: passes within normal range (9-17)' do
        ps = create_permission_set(allowed_hours_start: 9, allowed_hours_end: 17)
        assert evaluate(ps, { time: time_at_hour(10) })
      end

      test 'hours: passes at exact start hour' do
        ps = create_permission_set(allowed_hours_start: 9, allowed_hours_end: 17)
        assert evaluate(ps, { time: time_at_hour(9) })
      end

      test 'hours: fails at exact end hour' do
        ps = create_permission_set(allowed_hours_start: 9, allowed_hours_end: 17)
        assert_not evaluate(ps, { time: time_at_hour(17) })
      end

      test 'hours: fails outside normal range' do
        ps = create_permission_set(allowed_hours_start: 9, allowed_hours_end: 17)
        assert_not evaluate(ps, { time: time_at_hour(20) })
      end

      test 'hours: midnight wrap — passes during late night (22-06)' do
        ps = create_permission_set(allowed_hours_start: 22, allowed_hours_end: 6)
        assert evaluate(ps, { time: time_at_hour(23) })
        assert evaluate(ps, { time: time_at_hour(0) })
        assert evaluate(ps, { time: time_at_hour(3) })
      end

      test 'hours: midnight wrap — fails during daytime (22-06)' do
        ps = create_permission_set(allowed_hours_start: 22, allowed_hours_end: 6)
        assert_not evaluate(ps, { time: time_at_hour(10) })
        assert_not evaluate(ps, { time: time_at_hour(15) })
      end

      # A window with one hour of the two, the same hour twice, or an hour
      # outside 0..23 (written past the model) cannot be judged: a granting
      # set never passes on it (it used to pass with one hour).
      test 'hours: a broken window never passes, at any hour' do
        [[nil, 17], [9, nil], [9, 9], [25, 3]].each do |from, to|
          ps = stored(allowed_hours_start: from, allowed_hours_end: to)

          (0..23).each { |hour| assert_not evaluate(ps, { time: time_at_hour(hour) }), "#{[from, to].inspect} at #{hour}" }
          assert PermissionSetConditionEvaluator.unjudgeable?(permission_set: ps, context: { time: time_at_hour(12) })
          assert PermissionSetConditionEvaluator.broken?(permission_set: ps), [from, to].inspect
        end
      end

      # --- Broken IP lists -------------------------------------------------------

      test 'ip: a list with an entry that is not an IP cannot be judged and never passes' do
        ps = stored(allowed_ips: '10.0.0.0/8, office')

        assert_not evaluate(ps, { ip: '10.1.2.3' })
        assert PermissionSetConditionEvaluator.unjudgeable?(permission_set: ps, context: { ip: '10.1.2.3' })
        assert PermissionSetConditionEvaluator.broken?(permission_set: ps)
        assert_not PermissionSetConditionEvaluator.broken?(permission_set: stored(allowed_ips: '10.0.0.0/8'))
      end

      test 'ip: a list written with newlines or spaces is read entry by entry' do
        ps = stored(allowed_ips: "10.0.0.0/8\n192.168.0.0/16 203.0.113.9")

        assert evaluate(ps, { ip: '192.168.4.4' })
        assert evaluate(ps, { ip: '203.0.113.9' })
        assert_not evaluate(ps, { ip: '203.0.113.10' })
        assert_not PermissionSetConditionEvaluator.broken?(permission_set: ps)
      end

      test 'ip: separators alone are a list with no entry, which cannot be judged' do
        ps = stored(allowed_ips: ' , ')

        assert_not evaluate(ps, { ip: '10.1.2.3' })
        assert PermissionSetConditionEvaluator.broken?(permission_set: ps)
      end

      test 'unjudgeable? is false for a valid condition the context answers' do
        ps = stored(allowed_ips: '10.0.0.0/8', allowed_hours_start: 9, allowed_hours_end: 17)

        assert_not PermissionSetConditionEvaluator.unjudgeable?(permission_set: ps, context: { ip: '203.0.113.9' })
        assert PermissionSetConditionEvaluator.unjudgeable?(permission_set: ps, context: { session_flags: [] })
      end

      test 'hours: uses Time.current when no time in context' do
        # Use midnight wrap (0-0 would fail, so use a range that covers current hour)
        current_hour = Time.current.hour
        ps = create_permission_set(allowed_hours_start: current_hour, allowed_hours_end: (current_hour + 1) % 24)
        assert evaluate(ps, {})
      end

      # --- Combined conditions (all must pass) ---

      test 'combined: passes when all conditions met' do
        ps = create_permission_set(
          requires_session_flag: 'mfa_verified',
          allowed_ips: '192.168.1.0/24',
          allowed_hours_start: 9,
          allowed_hours_end: 17
        )
        context = { session_flags: ['mfa_verified'], ip: '192.168.1.5', time: time_at_hour(10) }
        assert evaluate(ps, context)
      end

      test 'combined: fails when session flag missing' do
        ps = create_permission_set(
          requires_session_flag: 'mfa_verified',
          allowed_ips: '192.168.1.0/24',
          allowed_hours_start: 9,
          allowed_hours_end: 17
        )
        context = { session_flags: [], ip: '192.168.1.5', time: time_at_hour(10) }
        assert_not evaluate(ps, context)
      end

      test 'combined: fails when IP not allowed' do
        ps = create_permission_set(
          requires_session_flag: 'mfa_verified',
          allowed_ips: '192.168.1.0/24',
          allowed_hours_start: 9,
          allowed_hours_end: 17
        )
        context = { session_flags: ['mfa_verified'], ip: '10.0.0.1', time: time_at_hour(10) }
        assert_not evaluate(ps, context)
      end

      test 'combined: fails when outside hours' do
        ps = create_permission_set(
          requires_session_flag: 'mfa_verified',
          allowed_ips: '192.168.1.0/24',
          allowed_hours_start: 9,
          allowed_hours_end: 17
        )
        context = { session_flags: ['mfa_verified'], ip: '192.168.1.5', time: time_at_hour(20) }
        assert_not evaluate(ps, context)
      end

      private

      def evaluate(permission_set, context)
        PermissionSetConditionEvaluator.call(permission_set: permission_set, context: context)
      end

      # A row as the table holds it, whatever the validations refuse today.
      def stored(**attrs)
        ps = create_permission_set
        ps.update_columns(attrs)
        ps.reload
      end

      def time_at_hour(hour)
        Time.current.change(hour: hour, min: 30)
      end
    end
  end
end
