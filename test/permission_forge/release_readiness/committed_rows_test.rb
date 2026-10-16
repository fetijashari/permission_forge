# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module ReleaseReadiness
    # The guard every test runs after its fixture rollback
    # (test/support/committed_rows.rb): rows committed past the rollback are
    # named and removed.
    class CommittedRowsTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      test 'a committed row is named, then removed' do
        user = create_user(name: 'Committed past the rollback')

        assert_equal %w[users], CommittedRows.changed.keys
        CommittedRows.remove!(CommittedRows.changed.keys)

        assert_empty CommittedRows.changed
        assert_not User.exists?(user.id)
      end

      test 'DDL is told apart from other statements' do
        assert_match CommittedRows::DDL, 'ALTER TABLE customers ADD pf_x varchar(255)'
        assert_match CommittedRows::DDL, '  create table pf_x (id integer)'
        assert_no_match CommittedRows::DDL, 'INSERT INTO customers (name) VALUES (1)'
        assert_no_match CommittedRows::DDL, 'SELECT 1 /* DROP TABLE */'
      end
    end
  end
end
