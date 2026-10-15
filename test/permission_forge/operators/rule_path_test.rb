# frozen_string_literal: true

require 'test_helper'
require_relative '../rule_path_models'

module PermissionForge
  module Operators
    # RulePath follows a join rule's association path the way ActiveRecord
    # joins it: every path ActiveRecord joins is followed, and every one it
    # raises for is broken — where, and why.
    class RulePathTest < ActiveSupport::TestCase
      test 'every path ActiveRecord joins is followed, to the model at its end' do
        PfRulePathRecord::JOINED.each do |path|
          followed = RulePath.follow(PfRulePathRecord, path.split('.'))

          assert_not followed.broken?, path
          PfRulePathRecord.joins(nested(path)).to_a # raises if ActiveRecord cannot join it
          assert_equal path.split('.').size + 1, followed.models.size, path
        end
        assert_equal [PfRulePathRecord, PfRulePathRecord, User], RulePath.follow(PfRulePathRecord, %w[parent owner]).models
        assert_equal [Customer, Supplier, User], RulePath.follow(Customer, %w[supplier owner]).models
      end

      test 'every path ActiveRecord raises for is broken, at the segment it raises for' do
        PfRulePathRecord::NOT_JOINED.each do |path, reason|
          followed = RulePath.follow(PfRulePathRecord, path.split('.'))

          assert followed.broken?, path
          assert_equal reason, followed.reason, path
          assert_empty followed.models, path
          assert_raises(StandardError, path) { PfRulePathRecord.joins(nested(path)).to_a }
        end
      end

      test 'it names the segment and the model it was looked up in' do
        followed = RulePath.follow(Customer, %w[supplier ownr owner])

        assert_equal ['ownr', Supplier, :unknown_association], [followed.segment, followed.owner, followed.reason]
        empty = RulePath.follow(PfRulePathRecord, ['parent', '', 'owner'])

        assert_equal ['', PfRulePathRecord], [empty.segment, empty.owner]
      end

      test 'no path is the model alone' do
        assert_equal [Customer], RulePath.follow(Customer, []).models
        assert_empty RuleColumn.path_segments(nil)
        assert_empty RuleColumn.path_segments(' ')
        assert_equal %w[supplier owner], RuleColumn.path_segments('supplier.owner')
      end

      private

      # The structure PermissionRuleApplier joins a dotted path with.
      def nested(path)
        path.split('.', -1).reverse.reduce({}) { |inner, name| { name.to_sym => inner } }
      end
    end
  end
end
