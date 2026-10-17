# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # ParamShapes.integer: what a whole-number parameter (a page, a page size,
  # a count) is read as — the number when it is one inside the range, the
  # default for every other shape. A typo in such a parameter is never 0, 1
  # or a 500 (R3 #29: `per_page=abc` listed one row).
  class ParamShapesTest < ActiveSupport::TestCase
    DEFAULT = 25

    # A trailing NUL byte is white space to String#strip: "7\0" is 7, an
    # Integer, so nothing of the byte goes further.
    READ = {
      '7' => 7, 7 => 7, ' 7 ' => 7, '007' => 7, ('9' * 40) => ('9' * 40).to_i, 1 => 1, "7\u0000" => 7
    }.freeze

    DEFAULTED = [
      '0', 0, '-1', -5, 'abc', '2abc', '1.5', 1.5, '', ' ', nil, true, [7], ['7'], { 'a' => '1' }, "7\u00008", '٧', '+7'
    ].freeze

    test 'a whole number inside the range is read, as digits or as a number' do
      READ.each do |value, expected|
        assert_equal expected, ParamShapes.integer(value, default: DEFAULT, range: 1..), value.inspect
      end
    end

    test 'anything else is the default: 0 and negatives below the range, text, fractions, lists, objects, blanks' do
      DEFAULTED.each do |value|
        assert_equal DEFAULT, ParamShapes.integer(value, default: DEFAULT, range: 1..), value.inspect
      end
    end

    test 'a number outside a bounded range is the default, not clamped' do
      assert_equal 23, ParamShapes.integer('23', default: nil, range: 0..23)
      assert_equal 0, ParamShapes.integer('0', default: nil, range: 0..23)
      assert_nil ParamShapes.integer('24', default: nil, range: 0..23)
      assert_nil ParamShapes.integer('-1', default: nil, range: 0..23)
    end

    test 'pf_integer_param reads params[key] the same way' do
      controller = Class.new do
        include PermissionForge::ParamShapes

        attr_reader :params

        def initialize(params) = @params = params
        public :pf_integer_param
      end
      params = ActionController::Parameters.new(page: '3', per_page: 'abc', days: ['9'])

      assert_equal 3, controller.new(params).pf_integer_param(:page, default: 1, range: 1..)
      assert_equal DEFAULT, controller.new(params).pf_integer_param(:per_page, default: DEFAULT, range: 1..)
      assert_equal 30, controller.new(params).pf_integer_param(:days, default: 30, range: 1..3650)
      assert_equal 30, controller.new(params).pf_integer_param(:missing, default: 30, range: 1..3650)
    end
  end
end
