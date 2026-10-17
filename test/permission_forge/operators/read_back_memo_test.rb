# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Operators
    # Review R1 #5 and #9: ValueCasters::PostgresqlTypes::ReadBack kept any
    # ActiveRecord::StatementInvalid as "PostgreSQL cannot read this" for the
    # life of the process — a statement timeout, a lock timeout or a lost
    # connection turned a good value into a rule that matched nothing until
    # a restart — and its memo ignored the database. Only a refusal of the
    # value itself (SQLSTATE class 22) is kept now; any other error denies
    # that one read. The CAST is stubbed, so this runs on every database.
    class ReadBackMemoTest < ActiveSupport::TestCase
      ReadBack = ValueCasters::PostgresqlTypes::ReadBack

      setup do
        skip 'the pg gem is not loaded' unless defined?(::PG::DataException)
        ReadBack.reset!
        @connection = Customer.connection
        @calls = 0
      end

      teardown do
        ReadBack.reset!
      end

      test 'a timeout, a lock timeout or a lost connection denies one read and is asked again' do
        [::PG::QueryCanceled, ::PG::LockNotAvailable, ::PG::ConnectionBad, ::PG::InFailedSqlTransaction].each do |error|
          ReadBack.reset!
          failing(error) { assert_not ReadBack.reads?(Customer, 'interval', '1 day'), error.name }
          answering('1 day') { assert ReadBack.reads?(Customer, 'interval', '1 day'), "#{error.name}: asked again" }
        end
      end

      test 'a refusal of the value (SQLSTATE class 22) is kept for the process' do
        failing(::PG::InvalidDatetimeFormat) { assert_not ReadBack.reads?(Customer, 'date', 'banana') }
        answering('banana') { assert_not ReadBack.reads?(Customer, 'date', 'banana') }

        assert_equal 1, @calls, 'asked once'
      end

      test 'the answers are kept per database' do
        answering('1 day') { assert ReadBack.reads?(Customer, 'interval', '1 day') }
        other = Struct.new(:name).new('other_db')
        model = Class.new do
          define_singleton_method(:connection_db_config) { other }
          define_singleton_method(:connection_pool) { Customer.connection_pool }
        end

        failing(::PG::InvalidTextRepresentation) { assert_not ReadBack.reads?(model, 'interval', '1 day') }
        assert_equal 2, @calls, 'the other database is asked itself'
      end

      private

      # The CAST raises `error_class` (as the cause of the StatementInvalid
      # ActiveRecord wraps it in) for the block.
      def failing(error_class, &)
        stub_select(lambda { |*|
          @calls += 1
          begin
            raise error_class, 'stubbed'
          rescue error_class
            raise ActiveRecord::StatementInvalid, 'stubbed'
          end
        }, &)
      end

      def answering(value, &)
        stub_select(lambda { |*|
          @calls += 1
          value
        }, &)
      end

      def stub_select(answer)
        original = @connection.method(:select_value)
        replace_singleton_method(@connection, :select_value) do |sql, *rest, **kw|
          sql.to_s.start_with?('SELECT CAST(') ? answer.call(sql) : original.call(sql, *rest, **kw)
        end
        yield
      ensure
        @connection.singleton_class.send(:remove_method, :select_value)
      end
    end
  end
end
