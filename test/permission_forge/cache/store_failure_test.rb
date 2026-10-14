# frozen_string_literal: true

require 'test_helper'
require_relative 'failing_store'

module PermissionForge
  module Cache
    # A cache store that swallows its errors (Redis, Memcached and Solid Cache
    # stores answer false or nil instead of raising) must not turn into a
    # silent loss of an invalidation, and never into wider access.
    class StoreFailureTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @other = create_user(name: 'Other')
        @set = create_permission_set
        [@user, @other].each { |user| create_permission_set_user(user: user, permission_set: @set) }
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @name = create_resource_field(resource: @resource, name: 'name')
        create_permission_set_rule(permission_set: @set, resource: @resource)

        @store = FailingStore.new
        PermissionForge.configuration.cache_backend = @store
        PermissionForge.configuration.reset_cache_store!
        @reported = []
        PermissionForge.configuration.on_cache_failure = ->(**failure) { @reported << failure }
        @key = @user.permission_cache_key
        @stamp_key = "user_#{@user.id}_invalidation"
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      # --- an invalidation the store does not confirm -----------------------------

      test 'a stamp write that fails once is tried again, and nothing is reported' do
        reader.permissions_hash
        failed = false
        @store.fail_when = lambda do |operation, key|
          next false unless operation == :write && key == @stamp_key && !failed

          failed = true
        end
        @store.operations.clear

        assert reader.invalidate_permissions

        assert_empty @reported
        assert_kind_of String, PermissionForge.cache.read(@stamp_key)
        assert_nil PermissionForge.cache.read(@key)
        assert_equal 2, @store.operations.count([:write, @stamp_key])
      end

      test 'a delete that fails silently once does not leave the entry' do
        reader.permissions_hash
        failed = false
        @store.fail_when = lambda do |operation, key|
          next false unless operation == :delete && key == @key && !failed

          failed = true
        end

        assert reader.invalidate_permissions

        assert_empty @reported
        assert_nil PermissionForge.cache.read(@key), 'overwritten with an empty entry when the delete did not confirm'
        assert_not reader.permissions_hash.empty?
      end

      test 'an invalidation the store never confirms is tried three times, reported and not raised' do
        reader.permissions_hash
        @store.operations.clear
        @store.down!
        events = []
        subscriber = ActiveSupport::Notifications.subscribe(Failure::EVENT) { |*, payload| events << payload }

        confirmed = nil
        assert_nothing_raised { confirmed = reader.invalidate_permissions }

        assert_equal false, confirmed
        assert_equal Invalidation::ATTEMPTS, @store.operations.count([:write, @stamp_key])
        assert_equal Invalidation::ATTEMPTS, @store.operations.count([:delete, @key]), 'the keys are tried every time'
        assert_equal 1, @reported.size
        failure = @reported.first
        assert_equal :invalidate, failure[:operation]
        assert_equal @user.id, failure[:user_id]
        assert_includes failure[:keys], @key
        assert_equal Invalidation::ATTEMPTS, failure[:attempts]
        assert_equal [failure], events
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      test 'the failure is logged at error level' do
        @store.down!
        log = StringIO.new
        logger = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(log)

        reader.invalidate_permissions

        assert_match(/\[PermissionForge\] cache invalidate failed for user #{@user.id}/, log.string)
        assert_match(/may be out of date until cache_ttl/, log.string)
      ensure
        Rails.logger = logger
      end

      test 'a store that raises is handled like one that answers false' do
        reader.permissions_hash
        @store.down!
        @store.raise_instead = true

        assert_nothing_raised { reader.invalidate_permissions }

        assert_equal 'the cache server is gone', @reported.first[:error].message
        assert_equal Invalidation::ATTEMPTS, @store.operations.count([:delete, @key])
      end

      test 'an error raised by the hook is swallowed' do
        @store.down!
        PermissionForge.configuration.on_cache_failure = ->(**) { raise 'the hook is broken' }

        assert_nothing_raised { reader.invalidate_permissions }
      end

      # The reviewer's F14: the subscriber's error used to leave the commit
      # callbacks, and Rails then skipped those of the remaining records.
      test 'a notification subscriber that raises stops neither the hook nor the invalidations of the commit' do
        other_set = create_permission_set(name: 'Second')
        third = create_user(name: 'Third')
        create_permission_set_user(user: third, permission_set: other_set)
        other_field = create_resource_field(resource: create_resource(permission_set: other_set, name: 'Supplier'), name: 'name')
        subscriber = ActiveSupport::Notifications.subscribe(Failure::EVENT) { |*| raise 'subscriber bug' }
        @store.down!
        log = capturing_log do
          assert_nothing_raised do
            ActiveRecord::Base.transaction do
              @name.update!(edit_access: true)
              other_field.update!(edit_access: true)
            end
          end
        end

        assert_equal [@user.id, @other.id, third.id].sort, @reported.map { |failure| failure[:user_id] }.sort
        assert_match(/cache_failure.permission_forge subscriber error: RuntimeError: subscriber bug/, log)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      test 'while the store keeps failing the next invalidations make one attempt' do
        @store.down!
        reader.invalidate_permissions
        attempts_of_the_first = @store.operations.count([:write, @stamp_key])
        other_stamp = "user_#{@other.id}_invalidation"

        User.find(@other.id).invalidate_permissions
        assert_equal Invalidation::ATTEMPTS, attempts_of_the_first
        assert_equal 1, @store.operations.count([:write, other_stamp])
        assert_equal 2, @reported.size

        @store.up!
        assert User.find(@other.id).invalidate_permissions
        @store.down!
        User.find(@other.id).invalidate_permissions
        assert_equal 1 + 1 + 1 + Invalidation::ATTEMPTS, @store.operations.count([:write, other_stamp]),
                     'it answered in between: the one that was owed is made, and the window is closed'
      end

      # --- the bookkeeping callers ask ---------------------------------------------

      test 'Failure.none? says whether the block got through without a reported failure' do
        invalidate = -> { reader.invalidate_permissions }
        assert_equal true, Failure.none?(&invalidate)

        @store.down!
        assert_equal false, Failure.none?(&invalidate)

        @store.up!
        assert_equal true, Failure.none?(&invalidate), 'an earlier failure is not held against a later block'
      end

      test 'Failure.none? counts what is reported on its own thread only' do
        @store.down!

        quiet = Failure.none? { Thread.new { User.find(@other.id).invalidate_permissions }.join }

        assert_equal true, quiet
        assert_equal 1, @reported.size
      end

      test 'Failure.none? passes an error of the block on' do
        broken = -> { raise 'the block is broken' }

        assert_raises(RuntimeError) { Failure.none?(&broken) }
      end

      # --- after_commit ------------------------------------------------------------

      test 'a commit whose invalidations fail raises nothing and reports each user once' do
        @store.down!
        email = nil

        assert_nothing_raised do
          ActiveRecord::Base.transaction do
            @name.update!(edit_access: true)
            email = create_resource_field(resource: @resource, name: 'email')
            @resource.update!(create_access: true)
          end
        end

        assert_predicate email, :persisted?
        assert_equal [@user.id, @other.id].sort, @reported.map { |failure| failure[:user_id] }.sort
      end

      # --- the store is down: nothing may widen access -----------------------------

      test 'with the store down permissions_hash is the hash that was built, never an empty one' do
        @store.down!
        person = reader

        hash = person.permissions_hash

        assert hash.dig(:permissions, :resources, :Customer, :permissions, :read_access)
        assert_equal 1, hash.dig(:permissions, :resources, :Customer, :permission_set_rules).size, 'the record rules are still there'
        assert person.can_read?(:Customer)
        assert_same hash, person.permissions_hash
        assert_empty @reported, 'nothing was stored, so nothing is left behind'
      end

      test 'with the store down a rebuild costs three calls and builds once' do
        @store.down!
        builds = counting_builds { reader.permissions_hash }

        assert_equal 1, builds
        assert_equal [[:read, @key], [:read, @stamp_key], [:write, @stamp_key]], @store.operations
      end

      test 'a store that drops what it is given still serves every request its hash' do
        @store.fail_when = ->(operation, _key) { operation == :write }

        2.times { assert reader.can_read?(:Customer) }
        assert_nil PermissionForge.cache.read(@key)
      end

      # A store without a failsafe raises where an ActiveSupport store answers
      # false; a rebuild treats both alike: the request gets the hash it built.
      test 'a store that raises on every write serves the hash that was built, like one that answers false' do
        @store.raise_instead = true
        @store.fail_when = ->(operation, _key) { operation == :write }

        builds = counting_builds { 2.times { assert reader.can_read?(:Customer) } }

        assert_equal 2, builds
        assert_nil PermissionForge.cache.read(@key)
      end

      test 'a hash too large for the store is built once per request, not twice' do
        @store.refuse = ->(value) { value.is_a?(Hash) }

        builds = counting_builds { assert reader.can_read?(:Customer) }

        assert_equal 1, builds
        assert_empty @reported
      end

      # --- the stamp cannot be read -------------------------------------------------

      # A read that fails answers nil, like a stamp that is not there. Two
      # empty reads prove nothing, so a rebuild first makes sure there is a
      # stamp it can read back.
      test 'a rebuild does not keep an entry when the stamp cannot be read' do
        @store.fail_when = ->(operation, key) { operation == :read && key == @stamp_key }

        assert reader.can_read?(:Customer)

        assert_nil PermissionForge.cache.read(@key)
      end

      test 'a rebuild that finds no stamp writes one and checks against it' do
        @store.clear
        person = reader

        @store.operations.clear

        person.permissions_hash

        assert_equal [[:read, @key], [:read, @stamp_key], [:write, @stamp_key], [:read, @stamp_key],
                      [:write, @key], [:read, @stamp_key]], @store.operations
        assert_kind_of String, PermissionForge.cache.read(@stamp_key)
        assert_not_nil PermissionForge.cache.read(@key)
      end

      # Both attempts of the rebuild fail the same way: one report, not two.
      test 'an entry that could not be verified and could not be removed is reported' do
        reads = 0
        @store.fail_when = lambda do |operation, key|
          next true if operation == :delete && key == @key
          next (reads += 1) == 2 if operation == :read && key == @stamp_key

          operation == :write && key == @key && reads >= 2
        end
        reader.invalidate_permissions
        @reported.clear
        reads = 0

        assert reader.can_read?(:Customer)

        assert_equal([:discard], @reported.map { |failure| failure[:operation] })
        assert_equal [@key], @reported.first[:keys]
      end

      # --- a real store that is not there ------------------------------------------

      test 'a Redis store nobody listens on: no error, a report, and the hash that was built' do
        require 'active_support/cache/redis_cache_store'
        store = ActiveSupport::Cache::RedisCacheStore.new(url: 'redis://127.0.0.1:1/15', pool: false, error_handler: ->(**) {},
                                                          reconnect_attempts: 0, connect_timeout: 0.2)
        PermissionForge.configuration.cache_backend = store
        PermissionForge.configuration.reset_cache_store!

        person = reader
        assert person.can_read?(:Customer)
        assert_equal 1, person.permissions_hash.dig(:permissions, :resources, :Customer, :permission_set_rules).size
        assert_nothing_raised { @name.update!(edit_access: true) }

        assert_equal(%i[invalidate invalidate], @reported.map { |failure| failure[:operation] })
        assert reader.field_permissions(:Customer, :name)[:edit_access]
      rescue LoadError
        skip 'the redis gem is not installed'
      end

      private

      def reader
        User.find(@user.id)
      end

      def capturing_log
        log = StringIO.new
        logger = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(log)
        yield
        log.string
      ensure
        Rails.logger = logger
      end

      def counting_builds
        builder = PermissionForge::Services::PermissionHashBuilder
        original = builder.method(:call)
        builds = 0
        replace_singleton_method(builder, :call) do |**options|
          builds += 1
          original.call(**options)
        end
        yield
        builds
      ensure
        replace_singleton_method(builder, :call, original)
      end
    end
  end
end
