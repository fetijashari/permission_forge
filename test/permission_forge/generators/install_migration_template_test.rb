require 'test_helper'
require 'erb'

module PermissionForge
  module Generators
    # The install migration template must add the tenant column to every table
    # when --tenant is given, and to none of them otherwise.
    class InstallMigrationTemplateTest < ActiveSupport::TestCase
      TABLE_COUNT = 9 # the 8 models' tables plus audit_events

      def render(tenant_column:)
        render_install_template('migration.rb.tt', tenant_column: tenant_column)
      end

      test 'template creates all 9 tables' do
        rendered = render(tenant_column: nil)
        assert_equal TABLE_COUNT, rendered.scan('create_table').size
      end

      test 'tenant column is added to every table when tenant is configured' do
        rendered = render(tenant_column: 'account_id')
        assert_equal TABLE_COUNT, rendered.scan(/t\.bigint\s+:account_id/).size
      end

      test 'no tenant column is added without tenant configuration' do
        rendered = render(tenant_column: nil)
        assert_no_match(/account_id/, rendered)
      end

      test 'rendered migration is valid Ruby in both modes' do
        [nil, 'account_id'].each do |tenant_column|
          rendered = render(tenant_column: tenant_column)
          assert RubyVM::InstructionSequence.compile(rendered), "invalid Ruby with tenant_column=#{tenant_column.inspect}"
        end
      end
    end
  end
end
