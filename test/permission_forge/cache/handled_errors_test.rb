# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Cache
    # HandledErrors: what a store rescued and handed to its error handler
    # during a call, which RailsCache#write_multi takes for a failed batch
    # whatever the store answered.
    class HandledErrorsTest < ActiveSupport::TestCase
      # A store that batches its writes and, like Rails 8.2's Redis store,
      # answers the same truthy value whether the batch went through or
      # not: a failure only reaches its error handler.
      class SilentBatchStore < ActiveSupport::Cache::MemoryStore
        attr_accessor :down

        def initialize(error_handler:, **)
          super(**)
          @error_handler = error_handler
        end

        private

        def write_multi_entries(entries, **options)
          if down
            @error_handler&.call(method: :write_multi_entries, exception: IOError.new('no server'), returning: nil)
          else
            super
          end
          { node: entries.keys }
        end
      end

      setup do
        @calls = []
        @handler = ->(**details) { @calls << details }
        @store = SilentBatchStore.new(error_handler: @handler)
        @cache = RailsCache.new(prefix: 'pfhandled', store: @store)
      end

      test 'a batch the store answered for but handed to its error handler counts as not written, the error yielded' do
        @store.down = true
        errors = []

        written = @cache.write_many({ 'a' => 1, 'b' => 2 }, ttl: 60) { |error| errors << error }

        assert_equal({ 'a' => false, 'b' => false }, written)
        assert_equal({ 'a' => false }, @cache.expunge_many(%w[a]))
        assert_equal ['no server'], errors.map(&:message)
        assert_equal %i[write_multi_entries write_multi_entries], @calls.pluck(:method), 'the store\'s own handler got every error'
      end

      test 'a batch with no error handed on is written, in one store call' do
        calls = []
        subscriber = ActiveSupport::Notifications.subscribe(/\Acache_\w+\.active_support\z/) { |name, *| calls << name }

        assert_equal({ 'a' => true, 'b' => true }, @cache.write_many({ 'a' => 1, 'b' => 2 }))
        assert_equal ['cache_write_multi.active_support'], calls
        assert_equal 1, @cache.read('a')
        assert_empty @calls
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      test 'the handler is wrapped once, and outside a watched call it only hands the error on' do
        @cache.write_many({ 'a' => 1 })
        wrapper = @store.instance_variable_get(:@error_handler)
        @cache.write_many({ 'a' => 1 })

        assert_kind_of HandledErrors::Handler, wrapper
        assert_same wrapper, @store.instance_variable_get(:@error_handler)

        error = IOError.new('elsewhere')
        wrapper.call(method: :read_entry, exception: error, returning: nil)
        assert_equal [{ method: :read_entry, exception: error, returning: nil }], @calls
        assert_nil ExecutionState[HandledErrors::KEY]
      end

      test 'a store given no error handler is watched all the same' do
        store = SilentBatchStore.new(error_handler: nil)
        store.down = true

        assert_equal({ 'a' => false }, RailsCache.new(store: store).write_many({ 'a' => 1 }))
      end

      test 'a handler called with other arguments gets them unchanged, and the call is noted' do
        received = []
        store = Class.new { def initialize(handler) = @error_handler = handler }.new(->(*args, **details) { received << [args, details] })

        value, handled = HandledErrors.during(store) do
          store.instance_variable_get(:@error_handler).call(:positional, detail: 1)
          :answer
        end

        assert_equal :answer, value
        assert_equal [nil], handled
        assert_equal [[[:positional], { detail: 1 }]], received
      end

      test 'a store without an error handler is not watched' do
        store = ActiveSupport::Cache::MemoryStore.new

        assert_equal [:answer, []], HandledErrors.during(store) { :answer }
        assert_not store.instance_variable_defined?(:@error_handler)
      end

      test 'watched calls nest: each sees its own errors, and the slot is put back' do
        wrapper = nil
        _, outer = HandledErrors.during(@store) do
          wrapper = @store.instance_variable_get(:@error_handler)
          _, inner = HandledErrors.during(@store) { wrapper.call(method: :inner, exception: IOError.new('inner'), returning: nil) }
          assert_equal ['inner'], inner.map(&:message)
          wrapper.call(method: :outer, exception: IOError.new('outer'), returning: nil)
        end

        assert_equal ['outer'], outer.map(&:message)
        assert_nil ExecutionState[HandledErrors::KEY]
      end
    end
  end
end
