# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Concerns
    # What the shapes below need: the user, the grant, and what is counted.
    module ShapeHelpers
      private

      def reader
        User.find(@user.id)
      end

      def cached
        PermissionForge.cache.read(@key)
      end

      def grant(user = @user)
        create_permission_set_user(user: user, permission_set: @set)
      end

      # No callbacks: nothing is invalidated.
      def grant_quietly
        PermissionForge::PermissionSetUser.insert({ uuid: SecureRandom.uuid, user_id: @user.id, permission_set_id: @set.id,
                                                    account_id: DEFAULT_TEST_ACCOUNT.id, created_at: Time.current, updated_at: Time.current })
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

      # The [operation, key] of every call to the cache inside the block.
      def store_calls(&)
        calls = []
        recording = ->(name) { ->(previous, key, *args, **options) { (calls << [name, key]) && previous.call(key, *args, **options) } }
        wrapping_cache(:read, recording[:read]) do
          wrapping_cache(:write, recording[:write]) { wrapping_cache(:delete, recording[:delete], &) }
        end
        calls
      end

      # Nests: what was there before is put back.
      def wrapping_cache(name, replacement)
        cache = PermissionForge.cache
        previous = cache.method(name)
        own = cache.singleton_class.method_defined?(name, false)
        replace_singleton_method(cache, name) { |*args, **options| replacement.call(previous, *args, **options) }
        yield
      ensure
        own ? replace_singleton_method(cache, name, previous) : cache.singleton_class.send(:remove_method, name)
      end

      def recording_invalidations
        calls = []
        User.define_method(:invalidate_permissions) do |tenant_id: nil|
          calls << [id, tenant_id]
          super(tenant_id: tenant_id)
        end
        yield
        calls
      ensure
        User.send(:remove_method, :invalidate_permissions)
      end
    end

    # Where a transaction is NOT treated as reading from a snapshot
    # (config.snapshot_transactions is false, or :auto on PostgreSQL at READ
    # COMMITTED), a transaction changes nothing: inside it a rebuild is
    # stored, regenerate_permissions stores at once, invalidate_permissions
    # invalidates at once and is not repeated, and the instance's hash is not
    # tied to the transaction — as it was before the transaction rule
    # existed (effb264).
    #
    # The expected answers and build counts in ShapesLikeBefore are what
    # effb264 gives for the same shapes (the reviewer's X2–X7 and the saves in
    # a loop); they were recorded by running the shapes against that tree.
    module ShapesLikeBefore
      extend ActiveSupport::Concern

      included do
        setup do
          @set = create_permission_set
          @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true, edit_access: true)
          %w[name email domain].each { |column| create_resource_field(resource: @resource, name: column, edit_access: true) }
          @user = create_user
          @key = @user.permission_cache_key
          @stamp_key = "user_#{@user.id}_invalidation"
        end

        # --- store calls: the same inside a transaction as outside one -------------------

        test 'a cache miss is rebuilt and stored inside a transaction exactly as outside one' do
          grant
          outside = store_calls { reader.permissions_hash }
          PermissionForge.cache.delete(@key)

          inside = store_calls { ActiveRecord::Base.transaction { reader.permissions_hash } }

          assert_equal outside, inside
          assert_equal [[:read, @key], [:read, @stamp_key], [:write, @key], [:read, @stamp_key]], inside
          assert_not_nil cached
        end

        test 'regenerate_permissions stores at once inside a transaction, and nothing follows at the commit' do
          grant
          outside = store_calls { reader.regenerate_permissions }
          inside = nil

          whole = store_calls do
            ActiveRecord::Base.transaction do
              inside = store_calls { reader.regenerate_permissions }
              assert_not_nil cached, 'stored before the commit'
            end
          end

          assert_equal outside, inside
          assert_equal [[:read, @stamp_key], [:write, @key], [:read, @stamp_key]], inside
          assert_equal inside + [[:read, @key]], whole, 'the read is the test looking at the entry'
        end

        test 'invalidate_permissions invalidates at once inside a transaction, and is not repeated at the commit' do
          grant
          reader.permissions_hash
          outside = store_calls { reader.invalidate_permissions }
          reader.permissions_hash
          calls = []

          inside = store_calls do
            calls = recording_invalidations { ActiveRecord::Base.transaction { reader.invalidate_permissions } }
          end

          assert_equal outside, inside
          assert_equal 1, calls.size
          assert_nil cached
        end

        test 'no transaction is withheld, and the hash an instance holds is not tied to one' do
          grant
          person = reader
          hash = nil

          ActiveRecord::Base.transaction do
            assert_nil PermissionForge::OpenTransaction.withholding
            hash = person.permissions_hash
          end

          assert_same hash, person.permissions_hash, 'kept after the transaction: it is the entry everybody reads'
        end

        # --- the reviewer's shapes ------------------------------------------------------------

        test 'X2 a grant with callbacks inside a transaction shows after the commit' do
          person = reader
          assert_not person.can_read?(:Customer)

          inside = ActiveRecord::Base.transaction do
            grant(person)
            [person.can_read?(:Customer), reader.can_read?(:Customer)]
          end

          assert_equal [false, false], inside, 'the invalidation comes after the commit'
          assert_equal [true, true], [person.can_read?(:Customer), reader.can_read?(:Customer)]
        end

        test 'X3 and X4: a grant without callbacks and regenerate_permissions inside a transaction, warm and cold' do
          %i[warm cold].each do |entry|
            PermissionForge::PermissionSetUser.where(user_id: @user.id).delete_all
            reader.invalidate_permissions
            person = reader
            person.can_read?(:Customer) if entry == :warm

            inside = ActiveRecord::Base.transaction do
              grant_quietly
              person.regenerate_permissions
              [person.can_read?(:Customer), reader.can_read?(:Customer)]
            end

            assert_equal [true, true], inside, "#{entry}: the same object, and a newly loaded one"
            assert_equal [true, true], [person.can_read?(:Customer), reader.can_read?(:Customer)], entry
            assert_not_nil cached, entry
          end
        end

        test 'X5 regenerate_permissions inside a transaction primes the shared cache' do
          grant_quietly

          ActiveRecord::Base.transaction { reader.regenerate_permissions }

          assert cached.dig(:permissions, :resources, :Customer)
        end

        test 'X6 under a second transaction that is not joinable everything is cached as usual' do
          connection = ActiveRecord::Base.connection
          connection.begin_transaction(joinable: false)

          builds = counting_builds do
            grant
            assert_equal [true], Array.new(10) { reader.can_read?(:Customer) }.uniq
            reader.regenerate_permissions
          end

          assert_equal 2, builds, 'one for the ten requests, one for regenerate_permissions'
          assert_not_nil cached
        ensure
          connection.rollback_transaction
        end

        test 'X7 a revocation inside a transaction is seen by another instance inside it' do
          grant
          assert reader.can_read?(:Customer)
          person = reader

          inside = ActiveRecord::Base.transaction do
            PermissionForge::PermissionSetUser.where(user_id: @user.id).delete_all
            person.regenerate_permissions
            reader.can_read?(:Customer)
          end

          assert_equal [false, false], [inside, reader.can_read?(:Customer)]
        end

        # Known limit, as before: the cache keeps what was stored from inside a
        # transaction that then rolls back. The remedy is to invalidate after
        # the rollback.
        test 'a grant that is rolled back stays cached until the user is invalidated' do
          person = reader

          ActiveRecord::Base.transaction do
            grant_quietly
            person.regenerate_permissions
            raise ActiveRecord::Rollback
          end

          assert_equal [true, true], [person.can_read?(:Customer), reader.can_read?(:Customer)]
          person.invalidate_permissions
          assert_equal [false, false], [person.can_read?(:Customer), reader.can_read?(:Customer)]
        end

        # A job that saves records in a loop: every save is a transaction of its
        # own, and with MaskedAttributes on the model the permissions are read
        # inside it.
        test 'saves in a loop on a cold entry build the hash once and leave it cached' do
          grant
          customers = Array.new(10) { |i| create_customer(name: "C#{i}") }
          reader.permissions_hash
          PermissionForge.cache.delete(@key)
          Current.user = reader
          loaded = Customer.where(id: customers.map(&:id)).to_a

          builds = counting_builds { loaded.each_with_index { |customer, i| customer.update!(domain: "x#{i}.test") } }

          assert_equal 1, builds
          assert_not_nil cached
          assert_equal(0, counting_builds { loaded.each_with_index { |customer, i| customer.update!(domain: "y#{i}.test") } })
        ensure
          Current.reset
        end
      end

      include ShapeHelpers
    end

    # With the option switched off, on whatever database the suite runs.
    class PermissionsTransactionPassthroughTest < ActiveSupport::TestCase
      include ShapesLikeBefore

      setup { PermissionForge.configuration.snapshot_transactions = false }
    end

    # With the option left at :auto, on PostgreSQL: READ COMMITTED is not a
    # snapshot, so nothing changes there without anybody configuring anything.
    class PermissionsTransactionAutoOnPostgresTest < ActiveSupport::TestCase
      include ShapesLikeBefore

      setup do
        skip 'needs PostgreSQL (DB=postgres)' unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
        assert_equal :auto, PermissionForge.configuration.snapshot_transactions
      end
    end

    # With the option left at :auto, on a database whose transactions read
    # from a snapshot (SQLite, the suite's default; MySQL): the hash is
    # withheld.
    class PermissionsTransactionAutoOnSnapshotDatabaseTest < ActiveSupport::TestCase
      setup do
        skip 'PostgreSQL reads committed rows' if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
        @user = create_user
        set = create_permission_set
        create_permission_set_user(user: @user, permission_set: set)
        create_resource(permission_set: set, name: 'Customer', read_access: true)
        PermissionForge.cache.delete(@user.permission_cache_key)
      end

      test 'auto: a rebuild inside a transaction is used by the request and not cached' do
        ActiveRecord::Base.transaction do
          assert_not_nil PermissionForge::OpenTransaction.withholding
          assert User.find(@user.id).can_read?(:Customer)
        end

        assert_nil PermissionForge.cache.read(@user.permission_cache_key)
      end
    end
  end
end
