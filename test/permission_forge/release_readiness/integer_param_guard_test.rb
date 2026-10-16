# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/static_guard'

module PermissionForge
  module ReleaseReadiness
    # A whole number from a request has one reader, ParamShapes.integer
    # (pf_integer_param): digits with an optional minus, inside a range, else
    # a default. `.to_i` reads "2abc" as 2, "-1" as -1 and a 40-digit number
    # as itself, which made the person list's page "2abc" page 2, a negative
    # remove_step a 500 and a Hash in `days` a 500 (R2 review, P2-1).
    class IntegerParamGuardTest < ActiveSupport::TestCase
      GLOBS = %w[app/**/*.rb app/**/*.erb lib/permission_forge/admin/**/*.rb].freeze
      NEEDLE = /\bparams\[[^\]]+\](?:\.to_s)?\.to_i\b|\.to_s\.to_i\b/
      ALLOWLIST = [].freeze
      FIXTURE = 'test/permission_forge/release_readiness/fixtures/reads_integer_param.rb'

      test 'no request value is read with to_i' do
        assert_empty StaticGuard.scan(globs: GLOBS, needle: NEEDLE, allowlist: ALLOWLIST).map(&:to_s),
                     'read a whole number with ParamShapes.integer / pf_integer_param'
      end

      test 'negative fixture: both shapes are hits' do
        hits = StaticGuard.scan(globs: [FIXTURE], needle: NEEDLE)

        assert_equal 2, hits.size, hits.map(&:to_s).inspect
      end

      test 'a page that is not a whole number is the first page of people' do
        create_user(name: 'Ana')

        assert_equal 1, PermissionForge::Admin::PeopleDirectory.new.search(page: '2abc', per_page: 1).page
        assert_equal 1, PermissionForge::Admin::PeopleDirectory.new.search(page: { 'a' => '1' }, per_page: 1).page
      end

      test 'the audit log reads its page with the one reader: a number past the last page is the last page' do
        assert_equal 1, PermissionForge::Admin::AuditLog.page_number('2abc', 120, 50)
        assert_equal 1, PermissionForge::Admin::AuditLog.page_number('-2', 120, 50)
        assert_equal 3, PermissionForge::Admin::AuditLog.page_number('9' * 40, 120, 50)
        assert_equal 2, PermissionForge::Admin::AuditLog.page_number(2, 120, 50)
      end
    end
  end
end
