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

      test 'unknown strategy raises ArgumentError' do
        assert_raises(ArgumentError) { MaskValue.call('test', strategy: 'unknown') }
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
