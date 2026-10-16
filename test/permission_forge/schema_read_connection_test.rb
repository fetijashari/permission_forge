# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # SchemaRead (and every reader built on it) never calls a model's
  # `connection`: from Rails 7.2 it raises under
  # `ActiveRecord.permanent_connection_checkout = :disallowed` in a thread
  # that holds no lease — a request or a job in an application that chose
  # it. Each call runs in a new thread that starts without one; the test's
  # transaction pins the connection, so the thread sees the same rows.
  class SchemaReadConnectionTest < ActiveSupport::TestCase
    def pool
      ActiveRecord::Base.connection_pool
    end

    # Rails 7.2+: the deprecated reader raises.
    def with_connection_reader_disallowed
      skip 'ActiveRecord.permanent_connection_checkout arrived in Rails 7.2' unless ActiveRecord.respond_to?(:permanent_connection_checkout=)

      previous = ActiveRecord.permanent_connection_checkout
      ActiveRecord.permanent_connection_checkout = :disallowed
      yield
    ensure
      ActiveRecord.permanent_connection_checkout = previous if ActiveRecord.respond_to?(:permanent_connection_checkout=)
    end

    # Runs the block in a new thread whose connection lease is not
    # permanent, and hands back what it returned (an error is raised here).
    def in_fresh_thread(&block)
      Thread.new do
        Thread.current.report_on_exception = false
        block.call
      end.value
    end

    test 'the column and table reads work where the deprecated connection reader raises' do
      with_connection_reader_disallowed do
        assert_raises(ActiveRecord::ActiveRecordError) { in_fresh_thread { Customer.connection } }

        answers = in_fresh_thread do
          [SchemaRead.column?(Customer, 'email'), SchemaRead.column?(Customer, 'no_such_column_here'),
           SchemaRead.table?(Customer, Customer.table_name), SchemaRead.table?(Customer, 'no_such_table_here'),
           SchemaRead.columns(Customer, verify: true).key?('email'), SchemaRead.column_names(Customer, verify: true).include?('email'),
           SchemaRead.columns_among(Customer, %w[email nope]), SchemaRead.column(Customer, 'email')&.name]
        end

        assert_equal [true, false, true, false, true, true, ['email'], 'email'], answers
      end
    end

    # The rule applier quotes a rule's column on every scoped read: a holder
    # of a rule would get an error for every record.
    test 'a record rule is applied where the deprecated connection reader raises' do
      user = create_user
      set = create_permission_set
      create_permission_set_user(user: user, permission_set: set)
      resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
      create_permission_set_rule(permission_set: set, resource: resource, field_name: 'name', field_value: 'mine', include_nulls: false)
      mine = create_customer(name: 'mine')
      create_customer(name: 'theirs')
      rules = user.permissions_hash.dig(:permissions, :resources, :Customer, :permission_set_rules)

      with_connection_reader_disallowed do
        ids = in_fresh_thread do
          Services::PermissionRuleApplier.scope(model_class: Customer, rules: rules, current_user: user).pluck(:id)
        end
        assert_equal [mine.id], ids
        assert_match(/CREATE POLICY/, in_fresh_thread { Services::RlsPolicyGenerator.call(model_class: Customer)[:statements].join })
      end
    end

    test 'the timestamps of a model are read where the deprecated connection reader raises' do
      with_connection_reader_disallowed do
        assert_equal(%w[created_at updated_at], in_fresh_thread { TimestampFields.names(Customer).sort })
      end
    end

    test 'a Permission Set saves with tenancy on, and the tenant readers answer, where the deprecated reader raises' do
      assert PermissionForge.configuration.tenant_enabled?, 'the suite runs with tenancy on'
      with_connection_reader_disallowed do
        saved, column, scoped = in_fresh_thread do
          ActsAsTenant.current_tenant = DEFAULT_TEST_ACCOUNT # the thread's own (acts_as_tenant keeps it per thread)
          set = create_permission_set(name: "Disallowed #{SecureRandom.hex(3)}")
          [set.persisted?, AuditEvent.tenant_column, PermissionSetUser.of_tenant(DEFAULT_TEST_ACCOUNT.id).to_a]
        end

        assert saved
        assert_equal PermissionForge.configuration.resolved_tenant_column.to_s, column.to_s
        assert_kind_of Array, scoped
      end
    end

    test 'assigning a set and reading the permissions work where the deprecated connection reader raises' do
      with_connection_reader_disallowed do
        answers = in_fresh_thread do
          ActsAsTenant.current_tenant = DEFAULT_TEST_ACCOUNT
          user = create_user
          set = create_permission_set
          resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
          create_resource_field(resource: resource, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
          create_permission_set_user(user: user, permission_set: set)
          [user.reload.can_read?(:Customer), user.masked_field?(:Customer, :email), VirtualFields.new(Customer).names.class,
           PermissionSet.conditional.to_a.class, PermissionSet.named(set.name).count]
        end

        assert_equal [true, true, Array, Array, 1], answers
      end
    end

    test 'a timestamp row stays Read-only when the columns cannot be read (fail closed)' do
      read = SchemaRead.method(:columns_among)
      replace_singleton_method(SchemaRead, :columns_among) { |*| raise ActiveRecord::ConnectionNotEstablished, 'down' }

      assert_equal TimestampFields::NAMES, TimestampFields.names(Customer)
      overrides = TimestampFields.new(Customer, muting: false).overrides('updated_at', read: true)
      assert_equal({ read_access: true, edit_access: false, mask_access: false }, overrides)
    ensure
      replace_singleton_method(SchemaRead, :columns_among, read)
    end

    test 'a rule column is resolved where the deprecated connection reader raises' do
      with_connection_reader_disallowed do
        found = in_fresh_thread { PermissionForge::Operators::RuleColumn.find('email', [Customer])&.column&.name }

        assert_equal 'email', found
      end
    end
  end
end
