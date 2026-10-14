# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Audit
    # The per-request store the actor, source, request id, IP, reason and
    # correlation id live in: nestable, inner values win, always restored, and
    # never shared between threads.
    class ContextTest < ActiveSupport::TestCase
      test 'is empty by default' do
        assert_equal({}, Context.current)
        assert_nil Context[:source]
      end

      test 'with sets slots for the block and restores them after' do
        Context.with(source: 'rake', reason: 'TCK-1') do
          assert_equal 'rake', Context[:source]
          assert_equal 'TCK-1', Context[:reason]
        end
        assert_equal({}, Context.current)
      end

      test 'nested blocks merge, inner values override outer, and the outer is restored' do
        Context.with(source: 'admin_ui', request_id: 'req-1') do
          Context.with(source: 'service') do
            assert_equal 'service', Context[:source]
            assert_equal 'req-1', Context[:request_id]
          end
          assert_equal 'admin_ui', Context[:source]
          assert_equal 'req-1', Context[:request_id]
        end
      end

      test 'a nil slot leaves the outer value in place' do
        Context.with(reason: 'outer') do
          Context.with(reason: nil) { assert_equal 'outer', Context[:reason] }
        end
      end

      test 'with returns the value of the block' do
        assert_equal 42, Context.with(source: 'job') { 42 }
      end

      test 'the outer context is restored when the block raises' do
        Context.with(source: 'admin_ui') do
          assert_raises(RuntimeError) { Context.with(source: 'api') { raise 'boom' } }
          assert_equal 'admin_ui', Context[:source]
        end
        assert_equal({}, Context.current)
      end

      test 'an unknown slot raises' do
        assert_raises(ArgumentError) { Context.with(colour: 'red') { nil } }
      end

      test 'the current context is frozen: callers cannot write through it' do
        Context.with(source: 'api') { assert_raises(FrozenError) { Context.current[:source] = 'x' } }
      end

      test 'reset! empties the context of this thread' do
        Context.with(source: 'api') do
          Context.reset!
          assert_equal({}, Context.current)
        end
      end

      test 'context does not leak to another thread, nor from it' do
        Context.with(source: 'admin_ui', reason: 'main') do
          seen = Thread.new { [Context.current, Context.with(source: 'job') { Context[:source] }] }.value
          assert_equal [{}, 'job'], seen
          assert_equal 'admin_ui', Context[:source]
        end
      end

      test 'under fiber isolation a fiber starts with an empty context' do
        previous = ActiveSupport::IsolatedExecutionState.isolation_level
        ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
        Context.with(source: 'admin_ui') do
          assert_equal({}, Fiber.new { Context.current }.resume)
          assert_equal 'admin_ui', Context[:source]
        end
      ensure
        ActiveSupport::IsolatedExecutionState.isolation_level = previous
      end

      test 'an actor given as a user is coerced to an Actor' do
        user = create_user(name: 'Ada Lovelace')
        Context.with(actor: user) do
          actor = Context[:actor]
          assert_instance_of Actor, actor
          assert_equal 'user', actor.type
          assert_equal user.id.to_s, actor.id
          assert_equal 'Ada Lovelace', actor.label
        end
      end
    end

    class ActorTest < ActiveSupport::TestCase
      test 'with nothing set the actor is unknown' do
        actor = Actor.current
        assert_equal 'unknown', actor.type
        assert_nil actor.id
        assert_nil actor.label
      end

      test 'PermissionForge.current_user is the actor when no context says otherwise' do
        Current.user = create_user(name: 'Grace Hopper')
        actor = Actor.current
        assert_equal %w[user], [actor.type]
        assert_equal Current.user.id.to_s, actor.id
        assert_equal 'Grace Hopper', actor.label
      end

      test 'a context actor wins over the current user' do
        Current.user = create_user(name: 'Request User')
        Context.with(actor: Actor.new(type: 'basic_auth', label: 'ops')) do
          assert_equal 'basic_auth', Actor.current.type
          assert_equal 'ops', Actor.current.label
        end
      end

      test 'an explicit with_audit_actor block wins over the request context' do
        Current.user = create_user(name: 'Request User')
        Context.with(actor: Actor.new(type: 'basic_auth', label: 'ops')) do
          PermissionForge.with_audit_actor(label: 'nightly job', type: 'system', source: 'job') do
            assert_equal 'system', Actor.current.type
            assert_equal 'nightly job', Actor.current.label
            assert_equal 'job', Context[:source]
          end
          assert_equal 'basic_auth', Actor.current.type
        end
      end

      test 'with_audit_actor takes a user and an optional label' do
        user = create_user(name: 'Ada')
        PermissionForge.with_audit_actor(user: user) { assert_equal ['user', user.id.to_s, 'Ada'], Actor.current.to_a }
        PermissionForge.with_audit_actor(user: user, label: 'Ada (API key 7)', type: 'api') do
          assert_equal ['api', user.id.to_s, 'Ada (API key 7)'], Actor.current.to_a
        end
      end

      test 'with_audit_actor with only a label records a system actor' do
        PermissionForge.with_audit_actor(label: 'rake permission_forge:cleanup') do
          assert_equal ['system', nil, 'rake permission_forge:cleanup'], Actor.current.to_a
        end
      end

      test 'with_audit_actor with only a source leaves the actor alone' do
        Current.user = create_user(name: 'Ada')
        PermissionForge.with_audit_actor(source: 'rake') do
          assert_equal 'Ada', Actor.current.label
          assert_equal 'rake', Context[:source]
        end
      end

      test 'an actor type outside the contract is refused' do
        assert_raises(ArgumentError) { Actor.new(type: 'robot') }
        assert_raises(ArgumentError) { PermissionForge.with_audit_actor(label: 'x', type: 'robot') { nil } }
      end

      test 'coerce accepts an Actor, a user, a hash or nil' do
        user = create_user(name: 'Ada')
        actor = Actor.new(type: 'api', id: '7', label: 'key')
        assert_same actor, Actor.coerce(actor)
        assert_equal ['user', user.id.to_s, 'Ada'], Actor.coerce(user).to_a
        assert_equal ['basic_auth', nil, 'ops'], Actor.coerce({ type: 'basic_auth', label: 'ops' }).to_a
        assert_nil Actor.coerce(nil)
      end

      test 'a user label honours config.user_label_formatter' do
        PermissionForge.configuration.user_label_formatter = ->(u) { "<#{u.email}>" }
        user = create_user(name: 'Ada', email: 'ada@example.com')
        assert_equal '<ada@example.com>', Actor.for_user(user).label
      end
    end

    class CorrelationTest < ActiveSupport::TestCase
      test 'correlate gives one id to everything inside the block' do
        ids = []
        Audit.correlate do
          ids << Context[:correlation_id]
          Audit.correlate { ids << Context[:correlation_id] }
        end
        assert_equal 1, ids.uniq.size
        assert_not_nil ids.first
        assert_nil Context[:correlation_id]
      end

      test 'correlate accepts an id of the caller' do
        Audit.correlate('batch-9') { assert_equal 'batch-9', Context[:correlation_id] }
      end

      test 'correlate returns the value of the block' do
        assert_equal(:done, Audit.correlate { :done })
      end
    end

    # The process-level defaults for the source column: the console, a rake
    # task, else a service. Rake is loaded in the test process, so the test
    # drives the detection through its inputs.
    class SourceTest < ActiveSupport::TestCase
      test 'a context source wins' do
        Context.with(source: 'api') { assert_equal 'api', Source.current }
      end

      test 'without a context the source is service in a plain process' do
        assert_equal 'service', Source.current
      end

      test 'a rake task is detected from the tasks rake was started with' do
        assert_equal 'rake', Source.detect(rake_tasks: ['permission_forge:cleanup'], console: false)
      end

      test 'the console is detected before rake' do
        assert_equal 'console', Source.detect(rake_tasks: ['x'], console: true)
      end

      test 'an unknown source is refused by the context' do
        assert_raises(ArgumentError) { Context.with(source: 'carrier_pigeon') { nil } }
      end
    end
  end
end
