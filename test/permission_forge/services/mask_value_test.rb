require 'test_helper'

module PermissionForge
  module Services
    class MaskValueTest < ActiveSupport::TestCase
      # --- Full strategy ---

      test 'full strategy masks entire value' do
        assert_equal '********', MaskValue.call('anything', strategy: 'full')
      end

      test 'full strategy with short value' do
        assert_equal '********', MaskValue.call('ab', strategy: 'full')
      end

      # --- Email strategy ---

      test 'email strategy masks local part keeping first character' do
        assert_equal 'j***@example.com', MaskValue.call('john@example.com', strategy: 'email')
      end

      test 'email strategy with single-char local part' do
        assert_equal '*@example.com', MaskValue.call('j@example.com', strategy: 'email')
      end

      test 'email strategy falls back to full when no @ present' do
        assert_equal '********', MaskValue.call('not-an-email', strategy: 'email')
      end

      # --- Last4 strategy ---

      test 'last4 strategy shows last 4 characters' do
        assert_equal '*******7890', MaskValue.call('+1234567890', strategy: 'last4')
      end

      test 'last4 strategy with exactly 5 characters' do
        assert_equal '*bcde', MaskValue.call('abcde', strategy: 'last4')
      end

      test 'last4 strategy falls back to full when value is 4 or fewer chars' do
        assert_equal '********', MaskValue.call('abcd', strategy: 'last4')
      end

      # --- First1_last4 strategy ---

      test 'first1_last4 strategy shows first and last 4 characters' do
        assert_equal 'J*****mith', MaskValue.call('John Smith', strategy: 'first1_last4')
      end

      test 'first1_last4 strategy with exactly 6 characters' do
        assert_equal 'a*cdef', MaskValue.call('abcdef', strategy: 'first1_last4')
      end

      test 'first1_last4 strategy falls back to full when value is 5 or fewer chars' do
        assert_equal '********', MaskValue.call('abcde', strategy: 'first1_last4')
      end

      # --- Edge cases ---

      test 'returns nil as-is' do
        assert_nil MaskValue.call(nil, strategy: 'full')
      end

      test 'returns empty string as-is' do
        assert_equal '', MaskValue.call('', strategy: 'full')
      end

      # --- A strategy this app does not know (written past the model, or a
      # custom one since removed from the configuration) ---

      test 'call masks fully with a strategy it does not know, blank included, and never raises' do
        ['unknown', '', nil, 'gone', :nope].each do |strategy|
          assert_equal '********', MaskValue.call('a@b.com', strategy: strategy), strategy.inspect
        end
      end

      test 'call reports a strategy it does not know once per process per name: a warning and a notification' do
        MaskValue.reset_reports!
        notified = []
        subscriber = ActiveSupport::Notifications.subscribe(MaskValue::UNKNOWN_STRATEGY_EVENT) { |*, payload| notified << payload }
        logger = ActiveSupport::Logger.new(output = StringIO.new)
        old_logger = Rails.logger
        Rails.logger = logger

        3.times { MaskValue.call('secret', strategy: 'gone') }
        MaskValue.call('secret', strategy: 'other')

        assert_equal [{ strategy: 'gone', fallback: 'full' }, { strategy: 'other', fallback: 'full' }], notified
        assert_equal 1, output.string.scan('"gone"').size, output.string
        assert_match(/masked fully/, output.string)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
        Rails.logger = old_logger if old_logger
        MaskValue.reset_reports!
      end

      test 'call! raises for a strategy it does not know, for the admin preview and the validation' do
        error = assert_raises(ArgumentError) { MaskValue.call!('test', strategy: 'unknown') }

        assert_match(/Unknown mask strategy: "unknown"/, error.message)
        assert_equal 'j***@b.com', MaskValue.call!('john@b.com', strategy: 'email')
      end

      test 'known? is the one answer to "is this a strategy"' do
        assert MaskValue.known?('full')
        assert MaskValue.known?(:email)
        assert_not MaskValue.known?('gone')
        assert_not MaskValue.known?('')
        assert_not MaskValue.known?(nil)

        PermissionForge.configuration.custom_mask_strategies = { 'initials' => ->(value) { value[0] } }

        assert MaskValue.known?('initials')
        assert_equal 's', MaskValue.call('secret', strategy: 'initials')
      end

      test 'a custom strategy removed from the configuration masks fully from then on' do
        PermissionForge.configuration.custom_mask_strategies = { 'initials' => ->(value) { value[0] } }

        assert_equal 's', MaskValue.call('secret', strategy: 'initials')

        PermissionForge.configuration.custom_mask_strategies = {}

        assert_equal '********', MaskValue.call('secret', strategy: 'initials')
      end

      test 'converts non-string values to string' do
        assert_equal '********', MaskValue.call(12_345, strategy: 'full')
      end

      test 'STRATEGIES constant includes all strategies' do
        assert_equal %w[full email last4 first1_last4], MaskValue::STRATEGIES
      end
    end
  end
end
