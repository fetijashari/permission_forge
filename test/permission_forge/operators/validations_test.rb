require 'test_helper'

module PermissionForge
  module Operators
    class ValidationsTest < ActiveSupport::TestCase
      # --- Between ---

      test 'returns nil for valid between values' do
        assert_nil Validations.validate('between', '1,2')
      end

      test 'returns error for between with wrong number of values' do
        result = Validations.validate('between', '1,2,3')
        assert_equal :field_value, result[:field]
        assert_match(/exactly 2/, result[:message])
      end

      # --- In / Not-in ---

      test 'returns nil for valid in values' do
        assert_nil Validations.validate('in', 'a,b,c')
      end

      test 'returns error for in with empty values' do
        result = Validations.validate('in', ',,,')
        assert_equal :field_value, result[:field]
        assert_match(/at least 1/, result[:message])
      end

      test 'returns error for not_in with empty values' do
        result = Validations.validate('not_in', ',,,')
        assert_equal :field_value, result[:field]
      end

      # --- Equal / Not-equal (single value required) ---

      test 'returns nil for equal with valid value' do
        assert_nil Validations.validate('equal', 'some_value')
      end

      test 'returns nil for not_equal with valid value' do
        assert_nil Validations.validate('not_equal', '42')
      end

      # --- Contains / Not-contains / Starts-with / Ends-with ---

      test 'returns nil for contains with valid value' do
        assert_nil Validations.validate('contains', 'test')
      end

      test 'returns nil for not_contains with valid value' do
        assert_nil Validations.validate('not_contains', 'test')
      end

      test 'returns nil for starts_with with valid value' do
        assert_nil Validations.validate('starts_with', 'prefix')
      end

      test 'returns nil for ends_with with valid value' do
        assert_nil Validations.validate('ends_with', 'suffix')
      end

      # --- Numeric comparison operators ---

      test 'returns nil for greater_than with numeric value' do
        assert_nil Validations.validate('greater_than', '42')
      end

      test 'returns nil for greater_than with decimal value' do
        assert_nil Validations.validate('greater_than', '3.14')
      end

      test 'returns nil for greater_than with negative value' do
        assert_nil Validations.validate('greater_than', '-5')
      end

      test 'returns nil for greater_than with date value' do
        assert_nil Validations.validate('greater_than', '2026-01-01')
      end

      test 'returns error for greater_than with non-numeric value' do
        result = Validations.validate('greater_than', 'abc')
        assert_equal :field_value, result[:field]
        assert_match(/numeric or date/, result[:message])
      end

      test 'returns error for less_than with non-numeric value' do
        result = Validations.validate('less_than', 'xyz')
        assert_equal :field_value, result[:field]
        assert_match(/numeric or date/, result[:message])
      end

      test 'returns nil for less_than_or_equal with numeric value' do
        assert_nil Validations.validate('less_than_or_equal', '100')
      end

      test 'returns nil for greater_than_or_equal with numeric value' do
        assert_nil Validations.validate('greater_than_or_equal', '0')
      end

      # --- Null operators ---

      test 'returns nil for is_null with blank value' do
        assert_nil Validations.validate('is_null', '')
      end

      test 'returns nil for is_not_null with blank value' do
        assert_nil Validations.validate('is_not_null', '')
      end

      test 'returns warning for is_null with non-blank value' do
        result = Validations.validate('is_null', 'unexpected')
        assert_equal :field_value, result[:field]
        assert_match(/does not require/, result[:message])
      end

      test 'returns warning for is_not_null with non-blank value' do
        result = Validations.validate('is_not_null', 'unexpected')
        assert_equal :field_value, result[:field]
        assert_match(/does not require/, result[:message])
      end

      # --- Edge cases ---

      test 'returns nil for blank operator' do
        assert_nil Validations.validate('', 'value')
      end

      test 'returns nil for blank field_value' do
        assert_nil Validations.validate('between', '')
      end
    end
  end
end
