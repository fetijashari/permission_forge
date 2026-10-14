require 'test_helper'
require 'generators/permission_forge/install/install_generator'

module PermissionForge
  module Generators
    # Columns that store a host primary key (user ids, audit user ids, the
    # tenant id) must have the type of that key. A bigint column silently
    # truncates a UUID to its leading digits, so the generator detects the
    # key types and lets the installer override them.
    class InstallGeneratorKeyTypesTest < ActiveSupport::TestCase
      test 'user id type follows the configured user model primary key' do
        assert_equal 'bigint', generator.send(:user_id_type)

        PermissionForge.configuration.user_class = 'TextKeyUser'
        assert_equal 'string', generator.send(:user_id_type)
      end

      test 'an explicit --user-id-type wins over detection' do
        assert_equal 'uuid', generator('--user-id-type=uuid').send(:user_id_type)
      end

      test 'falls back to bigint, with a warning, when the user model cannot be inspected' do
        PermissionForge.configuration.user_class = 'NoSuchUserModel'
        type = nil

        output, = capture_io { type = generator.send(:user_id_type) }

        assert_equal 'bigint', type
        assert_match(/--user-id-type/, output)
      end

      test 'tenant id type follows the --tenant model primary key' do
        assert_equal 'bigint', generator('--tenant=Account').send(:tenant_id_type)
        assert_equal 'string', generator('--tenant=TextKeyTenant').send(:tenant_id_type)
        assert_equal 'uuid', generator('--tenant=TextKeyTenant', '--tenant-id-type=uuid').send(:tenant_id_type)
      end

      test 'unknown key types are rejected' do
        assert_raises(Thor::Error) { generator('--user-id-type=float').send(:user_id_type) }
        assert_raises(Thor::Error) { generator('--tenant=Account', '--tenant-id-type=float').send(:tenant_id_type) }
      end

      test 'the migration types every user reference with the user id type' do
        rendered = render_install_template('migration.rb.tt', user_id_type: 'uuid')

        assert_equal 2, rendered.scan('t.references :user, null: false, type: :uuid').size
        assert_equal 8, rendered.scan(/t\.uuid\s+:created_by_id/).size
        assert_equal 8, rendered.scan(/t\.uuid\s+:updated_by_id/).size
        assert_no_match(/t\.bigint\s+:(?:created|updated)_by_id/, rendered)
        # the audit log's user references (reviewer, acknowledger) follow the user key too
        assert_match(/t\.uuid\s+:reviewed_by_id/, rendered)
        assert_match(/t\.uuid\s+:sensitive_acknowledged_by_id/, rendered)
        assert RubyVM::InstructionSequence.compile(rendered)
      end

      test 'the migration types the tenant column with the tenant id type' do
        rendered = render_install_template('migration.rb.tt', tenant_column: 'account_id', tenant_id_type: 'uuid')

        assert_equal 9, rendered.scan(/t\.uuid\s+:account_id/).size # 8 permission tables + audit_events
        assert_equal 9, rendered.scan(/t\.index\s+:account_id/).size
        assert RubyVM::InstructionSequence.compile(rendered)
      end

      test 'integer-keyed hosts keep bigint columns' do
        rendered = render_install_template('migration.rb.tt', tenant_column: 'account_id')

        assert_equal 2, rendered.scan('t.references :user, null: false, type: :bigint').size
        assert_equal 16, rendered.scan(/t\.bigint\s+:(?:created|updated)_by_id/).size
        assert_equal 9, rendered.scan(/t\.bigint\s+:account_id/).size
      end

      private

      def generator(*flags)
        PermissionForge::Generators::InstallGenerator.new([], flags)
      end
    end
  end
end
