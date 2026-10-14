# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Concerns
    # One user instance read on two real connections: a thread inside a
    # transaction whose hashes are withheld (config.snapshot_transactions),
    # and another thread on a connection of its own, which sees only
    # committed rows. The suite's in-memory database has one connection, so
    # these tests run on a SQLite file of their own, reached through a role
    # of its own, and delete it afterwards. Skipped on other databases.
    class PermissionsMemoConnectionsTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      ROLE = :pf_memo_connections

      setup do
        skip 'needs SQLite' unless ActiveRecord::Base.connection.adapter_name.match?(/sqlite/i)

        @file = Rails.root.join('tmp', "pf_memo_connections_#{Process.pid}.sqlite3").to_s
        FileUtils.mkdir_p(File.dirname(@file))
        ActiveRecord::Base.connection_handler.establish_connection(
          { adapter: 'sqlite3', database: @file, pool: 5, timeout: 5000 }, role: ROLE
        )
        @previous_tenant = ActsAsTenant.test_tenant
        @schema_verbose = ActiveRecord::Schema.verbose
        PermissionForge.configuration.snapshot_transactions = true
        on_file do
          ActiveRecord::Schema.verbose = false
          load File.expand_path('../../dummy/db/schema.rb', __dir__)
          ActsAsTenant.test_tenant = nil
          @tenant = Account.create!(name: 'Connections')
          ActsAsTenant.test_tenant = @tenant
          @user = create_user
          set = create_permission_set
          create_permission_set_user(user: @user, permission_set: set)
          resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
          @name = create_resource_field(resource: resource, name: 'name')
        end
        PermissionForge.cache.clear
      end

      teardown do
        next unless @file

        PermissionForge.configuration.snapshot_transactions = :auto
        ActsAsTenant.test_tenant = @previous_tenant
        ActiveRecord::Schema.verbose = @schema_verbose
        ActiveRecord::Base.connection_handler.remove_connection_pool('ActiveRecord::Base', role: ROLE, shard: :default)
        FileUtils.rm_f(Dir["#{@file}*"])
        PermissionForge.cache.clear
      end

      test 'another connection reading the instance does not untie the transaction or take its hash' do
        on_file do
          person = User.find(@user.id)
          ActiveRecord::Base.transaction do
            @name.update!(edit_access: true)
            person.regenerate_permissions
            assert edit?(person.permissions_hash)

            elsewhere = on_another_connection { person.permissions_hash }

            assert_not edit?(elsewhere), 'another connection sees the committed rows'
            assert edit?(person.permissions_hash), "the transaction's own thread lost the hash it built"
            raise ActiveRecord::Rollback
          end
        end
      end

      test 'a withheld hash is not served on another connection, which reads the store' do
        on_file do
          person = User.find(@user.id)
          ActiveRecord::Base.transaction do
            @name.update!(edit_access: true)
            person.regenerate_permissions

            tie = person.instance_variable_get(:@_pf_permissions_memo).transaction
            seen = on_another_connection { [tie.own_connection?, tie.visible?, person.send(:pf_withholding_permissions?)] }

            assert_equal [true, true], [tie.own_connection?, tie.visible?]
            assert_equal [false, false, false], seen
            raise ActiveRecord::Rollback
          end
        end
      end

      private

      def edit?(hash)
        hash.dig(:permissions, :resources, :Customer, :fields, :name, :edit_access)
      end

      def on_file(&)
        ActiveRecord::Base.connected_to(role: ROLE, &)
      end

      # Runs the block on another thread, on a connection of its own.
      def on_another_connection(&block)
        tenant = @tenant
        Thread.new do
          ActsAsTenant.test_tenant = tenant
          on_file { ActiveRecord::Base.connection_pool.with_connection { block.call } }
        end.value
      end
    end
  end
end
