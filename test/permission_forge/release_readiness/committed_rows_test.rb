# frozen_string_literal: true

require 'test_helper'
require_relative '../rule_path_models'

module PermissionForge
  module ReleaseReadiness
    # The guard every test runs after its fixture rollback
    # (test/support/committed_rows.rb): rows committed past the rollback are
    # named and removed — by key, also in tables without an integer id — a
    # change that keeps the row count is seen, and a baseline row a test
    # deleted is reported and taken as gone, so only the test that left the
    # change fails. Each test puts the guard's baseline back.
    class CommittedRowsTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @saved = CommittedRows.baseline
      end

      teardown do
        CommittedRows.baseline = @saved
      end

      def connection = ActiveRecord::Base.connection

      test 'a committed row is named, then removed' do
        user = create_user(name: 'Committed past the rollback')

        assert_equal %w[users], CommittedRows.changed.keys
        CommittedRows.remove!(CommittedRows.changed.keys)

        assert_empty CommittedRows.changed
        assert_not User.exists?(user.id)
      end

      test 'check! reports a leak and puts the table back, so the next check passes' do
        create_user(name: 'Leaked')

        assert_match(/left committed rows .*users/, CommittedRows.check!)
        assert_nil CommittedRows.check!, 'the next test starts clean'
      end

      test 'rows in tables without an integer id are removed by their key' do
        stamp = "'2026-01-01', '2026-01-01'"
        connection.execute("INSERT INTO text_key_users (id, name, created_at, updated_at) VALUES ('pf-committed', 'Text key', #{stamp})")
        connection.execute("INSERT INTO text_key_tenants (id, name, created_at, updated_at) VALUES ('pf-committed', 'Text key', #{stamp})")
        connection.execute('INSERT INTO pf_rule_path_peers (record_id, peer_id) VALUES (900001, 900002)')
        connection.execute("INSERT INTO billing_invoices (uuid, number, created_at, updated_at) VALUES ('pf-committed', 'X', #{stamp})")

        assert_equal %w[billing_invoices pf_rule_path_peers text_key_tenants text_key_users], CommittedRows.changed.keys.sort
        assert_match(/left committed rows/, CommittedRows.check!)
        assert_empty CommittedRows.changed
        assert_equal 0, connection.select_value("SELECT COUNT(*) FROM text_key_users WHERE id = 'pf-committed'").to_i
        assert_equal 0, connection.select_value('SELECT COUNT(*) FROM pf_rule_path_peers WHERE record_id = 900001').to_i
      end

      test 'a change that keeps the row count is seen, and a deleted baseline row is reported, then taken as gone' do
        kept = create_user(name: 'Baseline row')
        CommittedRows.rebaseline!(%w[users])
        kept.destroy!
        create_user(name: 'Its replacement')

        assert_equal %w[users], CommittedRows.changed.keys, 'count unchanged, the highest id moved'
        report = CommittedRows.check!
        assert_match(/deleted rows the database had before .*users/, report)
        assert_nil CommittedRows.check!, 'the deleted row is reported once, never again'
        assert_not User.where(name: 'Its replacement').exists?
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
