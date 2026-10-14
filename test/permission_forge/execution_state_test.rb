require 'test_helper'
require 'ripper'

module PermissionForge
  # ExecutionState: the one place the gem keeps state for the code running
  # now (ActiveSupport::IsolatedExecutionState, by Rails' isolation level).
  class ExecutionStateTest < ActiveSupport::TestCase
    ROOT = File.expand_path('../..', __dir__)
    HELPER = 'lib/permission_forge/execution_state.rb'.freeze

    # Every constant the gem names a slot with, and the slot.
    SLOT_CONSTANTS = {
      'PermissionForge::SKIP_SCOPE_KEY' => :pf_skip_auto_scope,
      'PermissionForge::Concerns::AutoPermissionScoping::INTERNAL_SUSPENSION_KEY' => :pf_internal_scope_suspension,
      'PermissionForge::Concerns::AutoPermissionScoping::IN_HOOK_KEY' => :pf_in_auto_scope_hook,
      'PermissionForge::Concerns::PermissionsPerContext::BUILDING_KEY' => :pf_building_permission_keys,
      'PermissionForge::InvalidationBatch::THREAD_KEY' => :pf_open_invalidation_batch,
      'PermissionForge::Cache::Failure::COLLECT_KEY' => :pf_cache_failure_collectors,
      'PermissionForge::Cache::Failure::COUNT_KEY' => :pf_cache_failures,
      'PermissionForge::Audit::RuntimeEmission::EMITTING_KEY' => :pf_audit_emitting,
      'PermissionForge::Audit::FieldAccess::KEY' => :pf_audit_field_access,
      'PermissionForge::Concerns::MaskedAttributes::INSPECT_KEY' => :pf_inspecting,
      'PermissionForge::Concerns::MaskedAttributes::StoreAccess::RAW_STORE_KEY' => :pf_raw_store_columns,
      'PermissionForge::Concerns::MaskedAttributes::VirtualReaders::UNMASKED_KEY' => :pf_unmasked_virtual_records,
      'PermissionForge::Concerns::MaskedAttributes::ValidationReads::VALIDATING_KEY' => :pf_validating_records,
      'PermissionForge::Concerns::MaskedAttributes::ValidationReads::READS_KEY' => :pf_validation_reads,
      'PermissionForge::Concerns::MaskedAttributes::ValidationReads::WINDOWS_KEY' => :pf_validator_windows,
      'PermissionForge::Audit::Context::KEY' => :pf_audit_context,
      'PermissionForge::Audit::Context::TRANSACTION_KEY' => :pf_audit_transaction_correlation,
      'PermissionForge::Audit::Runtime::ONCE_KEY' => :pf_audit_runtime_once
    }.freeze

    # Where lib/ and app/ may keep per-thread, per-fiber or per-request state
    # without ExecutionState: path => { rule => why }.
    ALLOWED = {
      HELPER => {
        thread_current: 'the :fiber store (Thread#[]) of ExecutionState itself',
        fiber_state: 'RunHook notes the fiber a run started in',
        isolated_execution_state: 'the :execution store of ExecutionState itself'
      },
      'lib/permission_forge/controller_actions/managed_index.rb' => {
        current_attributes: 'ManagedIndex::RequestMemo: a per-request copy of the managed-actions index; ' \
                            'Rails resets CurrentAttributes before and after every request and job, and a stale ' \
                            'copy costs a store read, never a wrong answer (it carries the cache version)'
      }
    }.freeze

    THREAD_ATTRIBUTES = /\Athread_[mc]attr_(accessor|reader|writer)\z/

    # Ruby that reaches thread, fiber or request state: [line, rule, text].
    # Tokens, so a comment or a string mentioning it does not count; any use
    # of Thread.current or Fiber.current counts (an alias, send, fetch, key?,
    # then, method(:[]) all start there).
    def self.state_access(source)
      tokens = Ripper.lex(source).reject { |(_, kind, _)| %i[on_sp on_ignored_nl on_nl on_comment].include?(kind) }
      tokens.each_index.filter_map do |index|
        (line,), kind, text = tokens[index]
        following = tokens[(index + 1)..(index + 4)].map { |token| token[2] }.join
        rule = state_rule(kind, text, following)
        [line, rule, "#{text}#{following}"] if rule
      end
    end

    # constant => [rule, what may follow it to count ('' = anything)]
    CONSTANT_RULES = {
      'Thread' => [:thread_current, ['.current', '&.current']],
      'Fiber' => [:fiber_state, ['.current', '&.current', '[', '.[]', '.storage']],
      'IsolatedExecutionState' => [:isolated_execution_state, ['']],
      'CurrentAttributes' => [:current_attributes, ['']]
    }.freeze

    def self.state_rule(kind, text, following)
      return :thread_attributes if kind == :on_ident && text.match?(THREAD_ATTRIBUTES)

      rule, followers = CONSTANT_RULES[text] if kind == :on_const
      rule if rule && following.start_with?(*followers)
    end

    TEMPLATE_STATE = /Thread\s*\.\s*current|Fiber\s*(\[|\.\s*current)|IsolatedExecutionState|CurrentAttributes|thread_[mc]attr_/

    test 'no code in lib/ or app/ keeps thread, fiber or request state outside ExecutionState (ALLOWED aside)' do
      offenders = Dir[File.join(ROOT, '{app,lib}/**/*.rb')].flat_map do |path|
        relative = path.delete_prefix("#{ROOT}/")
        allowed = ALLOWED.fetch(relative, {})
        self.class.state_access(File.read(path)).filter_map do |line, rule, text|
          "#{relative}:#{line} #{rule} #{text}" unless allowed.key?(rule)
        end
      end
      templates = Dir[File.join(ROOT, '{app,lib}/**/*.{erb,tt}')].flat_map do |path|
        File.readlines(path).each_with_index.filter_map do |line, index|
          next if line.lstrip.start_with?('#', '<%#')

          "#{path.delete_prefix("#{ROOT}/")}:#{index + 1}" if line.match?(TEMPLATE_STATE)
        end
      end

      assert_empty offenders + templates, 'use PermissionForge::ExecutionState (and register the key in its KEYS), ' \
                                          'or add the file to ALLOWED with the reason'
    end

    test 'every ALLOWED entry is still used' do
      ALLOWED.each do |path, rules|
        found = self.class.state_access(File.read(File.join(ROOT, path))).map { |_, rule, _| rule }
        rules.each_key { |rule| assert_includes found, rule, "#{path}: #{rule} is no longer used — remove it from ALLOWED" }
      end
    end

    test 'the guard recognises the ways of reaching thread, fiber and request state' do
      caught = {
        'Thread.current[:a] = 1' => :thread_current,
        'Thread.current.send(:[], :a)' => :thread_current,
        'Thread.current.public_send(:[]=, :a, 1)' => :thread_current,
        'Thread.current.fetch(:a, nil)' => :thread_current,
        'Thread.current.key?(:a)' => :thread_current,
        "locals = Thread.current\nlocals[:a] = 1" => :thread_current,
        'Thread.current&.[](:a)' => :thread_current,
        '::Thread.current[:a]' => :thread_current,
        'Thread.current [:a]' => :thread_current,
        'Thread.current.[](:a)' => :thread_current,
        'Thread.current.thread_variable_set(:a, 1)' => :thread_current,
        'Thread.current.instance_variable_set(:@a, 1)' => :thread_current,
        'Thread.current.then { |t| t[:a] }' => :thread_current,
        'Thread.current.method(:[]).call(:a)' => :thread_current,
        'Fiber[:a] = 1' => :fiber_state,
        'Fiber.current.storage[:a]' => :fiber_state,
        'Fiber.current' => :fiber_state,
        'ActiveSupport::IsolatedExecutionState[:a]' => :isolated_execution_state,
        'ActiveSupport.const_get(:IsolatedExecutionState)[:a]' => :isolated_execution_state,
        "class PfCurrent < ActiveSupport::CurrentAttributes\n  attribute :a\nend" => :current_attributes,
        'thread_mattr_accessor :a' => :thread_attributes,
        'thread_cattr_reader :a' => :thread_attributes
      }
      caught.each do |source, rule|
        assert_includes self.class.state_access(source).map { |_, found, _| found }, rule, source
      end

      ignored = ['# Thread.current[:a] in a comment', '"Thread.current[:a] in a string"', 'Thread.new { 1 }', 'Mutex.new']
      ignored.each { |source| assert_empty self.class.state_access(source), source }
    end

    # The slots whose value, seen by code it was not set for, widens access or
    # drops audit events: kept per fiber whatever the isolation level.
    FIBER_SLOTS = %i[
      pf_skip_auto_scope pf_internal_scope_suspension pf_in_auto_scope_hook pf_building_permission_keys
      pf_raw_store_columns pf_unmasked_virtual_records pf_audit_emitting pf_audit_field_access pf_inspecting
      pf_validating_records pf_validation_reads pf_validator_windows
    ].freeze

    def self.thread_isolation?
      ActiveSupport::IsolatedExecutionState.isolation_level == :thread
    end

    test 'every slot is registered once, named pf_*, with where it is kept, what it holds and what a run end does' do
      assert_equal SLOT_CONSTANTS.values.sort, ExecutionState::KEYS.keys.sort, 'the registry lists exactly the slots the gem uses'
      SLOT_CONSTANTS.each { |constant, name| assert_equal name, constant.constantize, constant }
      ExecutionState::KEYS.each_value do |key|
        assert_match(/\Apf_/, key.name.to_s)
        assert_includes ExecutionState::SCOPES, key.scope, key.name
        assert_includes ExecutionState::AT_RUN_END, key.at_run_end, key.name
        assert key.holds.present?, key.name
      end
      assert_equal FIBER_SLOTS.sort, ExecutionState::KEYS.values.select { |key| key.scope == :fiber }.map(&:name).sort
    end

    test 'an unregistered key raises' do
      %i[[] delete].each do |method|
        assert_raises(ArgumentError) { ExecutionState.public_send(method, :pf_unknown) }
      end
      assert_raises(ArgumentError) { ExecutionState[:pf_unknown] = 1 }
      assert_raises(ArgumentError) { ExecutionState.with(:pf_unknown, 1) { flunk 'never runs' } }
      assert_raises(ArgumentError) { ExecutionState.fetch(:pf_unknown) { Set.new } }
    end

    test 'a fiber slot is kept fiber-locally, an execution slot in ActiveSupport::IsolatedExecutionState' do
      ExecutionState[:pf_inspecting] = :here
      ExecutionState[:pf_open_invalidation_batch] = :there

      assert_equal [:here, nil], [Thread.current[:pf_inspecting], ActiveSupport::IsolatedExecutionState[:pf_inspecting]]
      assert_equal [nil, :there], [Thread.current[:pf_open_invalidation_batch], ActiveSupport::IsolatedExecutionState[:pf_open_invalidation_batch]]
      assert_equal %i[here there], [ExecutionState.delete(:pf_inspecting), ExecutionState.delete(:pf_open_invalidation_batch)]
      assert_not Thread.current.key?(:pf_inspecting)
      assert_not ActiveSupport::IsolatedExecutionState.key?(:pf_open_invalidation_batch)
    end

    test 'fetch stores the block value when the slot is empty, and keeps what is there' do
      first = ExecutionState.fetch(:pf_building_permission_keys) { {} }
      assert_same first, ExecutionState.fetch(:pf_building_permission_keys) { flunk 'already there' }
      assert_same first, ExecutionState[:pf_building_permission_keys]
    end

    test 'with sets the slot for the block and puts back what was there, also when the block raises' do
      %i[pf_inspecting pf_open_invalidation_batch].each do |name|
        assert_equal :inner, ExecutionState.with(name, true) {
          ExecutionState.with(name, false) { assert_equal false, ExecutionState[name] }
          assert_equal true, ExecutionState[name]
          :inner
        }
        assert_not Thread.current.key?(name) || ActiveSupport::IsolatedExecutionState.key?(name), "#{name}: absent again"

        ExecutionState[name] = :outer
        assert_raises(RuntimeError) { ExecutionState.with(name, true) { raise 'boom' } }
        assert_equal :outer, ExecutionState[name]
      end
    end

    test 'reset! empties every slot' do
      ExecutionState::KEYS.each_key { |name| ExecutionState[name] = true }
      ExecutionState.reset!
      ExecutionState::KEYS.each_key do |name|
        assert_not Thread.current.key?(name) || ActiveSupport::IsolatedExecutionState.key?(name), name
      end
    end

    test 'another thread has a state of its own' do
      PermissionForge.without_permission_scope do
        assert_equal [false, true], Thread.new {
          [PermissionForge.scope_suspended?, PermissionForge.without_permission_scope { PermissionForge.scope_suspended? }]
        }.value
        assert PermissionForge.scope_suspended?
      end
    end

    # --- thread isolation (the default: Puma, Sidekiq) -------------------------------------------

    test 'under thread isolation another fiber of the thread sees no fiber slot, and the execution slots' do
      skip 'needs thread isolation' unless self.class.thread_isolation?

      FIBER_SLOTS.each do |name|
        ExecutionState.with(name, :set) { assert_nil Fiber.new { ExecutionState[name] }.resume, name }
      end
      # as it sees ActiveRecord's connection and CurrentAttributes
      Audit::Context.with(source: 'job') { assert_equal 'job', Fiber.new { Audit::Context[:source] }.resume }
    end

    test 'under thread isolation an Enumerator paused inside without_permission_scope does not leave the request unscoped' do
      skip 'needs thread isolation' unless self.class.thread_isolation?

      enumerator = Enumerator.new do |out|
        PermissionForge.without_permission_scope do
          out << PermissionForge.scope_suspended?
          out << PermissionForge.scope_suspended?
        end
      end

      assert enumerator.next, 'inside the enumerator, inside its block'
      assert_not PermissionForge.scope_suspended?, 'the request, while the enumerator is paused inside the block'
      PermissionForge.without_permission_scope { assert enumerator.next }
      assert_not PermissionForge.scope_suspended?
    end

    test 'under thread isolation an Enumerator paused inside any fiber slot leaves the request as it was' do
      skip 'needs thread isolation' unless self.class.thread_isolation?

      FIBER_SLOTS.each do |name|
        enumerator = Enumerator.new { |out| ExecutionState.with(name, :inside) { out << ExecutionState[name] } }
        assert_equal :inside, enumerator.next, name
        assert_nil ExecutionState[name], name
      end
    end

    test 'under thread isolation interleaved Cache::Failure.collect blocks each keep their own failures' do
      skip 'needs thread isolation' unless self.class.thread_isolation?

      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(StringIO.new)
      inner = nil
      enumerator = Enumerator.new do |out|
        inner = Cache::Failure.collect do
          out << :paused
          Cache::Failure.report(operation: :invalidate, user_id: 7)
        end
        out << :done
      end
      outer = Cache::Failure.collect { enumerator.next } # ends while the inner one is still open
      enumerator.next

      assert_equal [1, 0], [inner.to_a.size, outer.to_a.size], 'the outer one had ended when the failure came'
      assert_equal [], inner.confirmed([7])
      assert_empty ExecutionState[Cache::Failure::COLLECT_KEY]
    ensure
      Rails.logger = previous
    end

    # --- fiber isolation (a fiber-based server: Falcon) ------------------------------------------

    class FiberIsolationTest < ActiveSupport::TestCase
      setup do
        @previous_level = ActiveSupport::IsolatedExecutionState.isolation_level
        ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
      end

      teardown do
        ActiveSupport::IsolatedExecutionState.isolation_level = @previous_level
      end

      # A fiber that enters `wrap`, reports what it sees, pauses inside the
      # block, reports again after resuming, and once more after the block.
      def paused_inside(probe, &wrap)
        Fiber.new do
          wrap.call do
            Fiber.yield(probe.call)
            Fiber.yield(probe.call)
          end
          probe.call
        end
      end

      def assert_interleaves(probe, outside, inside, &)
        first = paused_inside(probe, &)
        second = paused_inside(probe, &)
        seen = [first.resume, probe.call, second.resume, first.resume, first.resume, second.resume, second.resume, probe.call]

        # first fiber inside its block, the main fiber, the second fiber inside
        # its block, the first one still inside after the second entered, the
        # first one after its block (restored), the second one still inside (the
        # first restored only its own state), the second one after its block,
        # the main fiber at the end
        assert_equal [inside, outside, inside, inside, outside, inside, outside, outside], seen
      end

      test 'without_permission_scope: each fiber suspends and restores only its own scope' do
        assert_interleaves(-> { PermissionForge.scope_suspended? }, false, true) do |&body|
          PermissionForge.without_permission_scope(&body)
        end
      end

      test 'the audit context: each fiber sees only its own' do
        assert_interleaves(-> { Audit::Context[:source] }, nil, 'job') do |&body|
          Audit::Context.with(source: 'job', &body)
        end
      end

      test 'Cache::Failure.collect and none?: a failure counts in the fiber it was reported in' do
        reported = lambda do
          collected = Cache::Failure.collect { Cache::Failure.report(operation: :invalidate, user_id: 7) }
          collected.to_a.size
        end
        capture_rails_log do
          other = Fiber.new { Cache::Failure.none? { Fiber.yield(reported.call) } }
          assert_equal 1, other.resume
          assert Cache::Failure.none? { other.resume }, 'nothing was reported in this fiber'
        end
      end

      test 'every slot: interleaved fibers restore only their own' do
        ExecutionState::KEYS.each_key do |name|
          assert_interleaves(-> { ExecutionState[name] }, nil, :inside) do |&body|
            ExecutionState.with(name, :inside, &body)
          end
        end
      end

      test 'a new fiber starts empty' do
        PermissionForge.without_permission_scope do
          Audit::Context.with(source: 'job') do
            assert_equal [false, nil], Fiber.new { [PermissionForge.scope_suspended?, Audit::Context[:source]] }.resume
          end
        end
      end

      private

      def capture_rails_log
        previous = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(StringIO.new)
        yield
      ensure
        Rails.logger = previous
      end
    end

    # --- the executor: one request (or job) after another on one thread -------------------------

    class ExecutorTest < ActiveSupport::TestCase
      def run_once(&)
        Rails.application.executor.wrap(&)
      end

      # What is left behind when a block never ends: a fiber abandoned inside it.
      def abandon_inside(&wrap)
        fiber = Fiber.new { wrap.call { Fiber.yield } }
        fiber.resume
        fiber
      end

      test 'every :clean slot set during a run is gone after it, and not there in the next run' do
        ExecutionState::CLEANED.each do |name|
          run_once { ExecutionState[name] = :leaked }
          assert_nil ExecutionState[name], "#{name} after the run"
          run_once { assert_nil ExecutionState[name], "#{name} in the next run" }
        end
      end

      test 'an Enumerator abandoned inside a block leaves nothing to the next request' do
        skip 'needs thread isolation' unless ExecutionStateTest.thread_isolation?

        seen = []
        run_once do
          scoped = Enumerator.new { |out| PermissionForge.without_permission_scope { out << :inside } }
          context = Enumerator.new { |out| Audit::Context.with(source: 'job') { out << :inside } }
          [scoped, context].each(&:next)
          # the scope stays in the enumerator's fiber; the audit context is
          # the thread's, as CurrentAttributes are
          seen << [PermissionForge.scope_suspended?, Audit::Context[:source]]
        end
        seen << [PermissionForge.scope_suspended?, Audit::Context[:source]]
        run_once { seen << [PermissionForge.scope_suspended?, Audit::Context[:source]] }

        assert_equal [[false, 'job'], [false, nil], [false, nil]], seen
      end

      test 'a fiber abandoned inside a block during a run leaves nothing behind' do
        run_once do
          abandon_inside { |&body| Audit::Context.with(source: 'job', &body) }
          abandon_inside { |&body| ExecutionState.with(:pf_audit_emitting, true, &body) }
        end

        assert_nil ExecutionState[:pf_audit_emitting]
        assert_nil Audit::Context[:source]
      end

      test 'a value set around the run stays: a block that wraps the whole run (a console around an inline job)' do
        PermissionForge.without_permission_scope do
          run_once { assert PermissionForge.scope_suspended?, 'inside the run' }
          assert PermissionForge.scope_suspended?, 'after the run, still inside the block'
        end
        assert_not PermissionForge.scope_suspended?
      end

      test 'a collection there when the run started loses only what the run added: nothing removed comes back' do
        outer = Object.new
        gone = Object.new
        unmasked = ExecutionState.fetch(:pf_unmasked_virtual_records) { Set.new.compare_by_identity }
        unmasked << outer << gone
        building = ExecutionState.fetch(:pf_building_permission_keys) { {} }
        building[:outer] = { instance: outer }

        run_once do
          unmasked << Object.new # never removed: a block that did not end
          unmasked.delete(gone) # its block ended during the run
          building[:added] = { instance: outer }
          building.delete(:outer)
          ExecutionState.fetch(:pf_raw_store_columns) { {}.compare_by_identity }[outer] = 'prefs'
        end

        assert_same unmasked, ExecutionState[:pf_unmasked_virtual_records]
        assert_equal [outer], unmasked.to_a
        assert unmasked.compare_by_identity?
        assert_same building, ExecutionState[:pf_building_permission_keys]
        assert_empty building, 'the key removed during the run is not put back (a REENTRANT {} with the rules off)'
        assert_nil ExecutionState[:pf_raw_store_columns]
      end

      test 'a slot that held a value when the run started is never written: a block that ended during the run stays ended' do
        snapshot = nil
        PermissionForge.without_permission_scope do
          snapshot = ExecutionState::RunHook.run
        end
        ExecutionState::RunHook.complete(snapshot)

        assert_not PermissionForge.scope_suspended?
      end

      test 'the failure collectors outlive a run: the open ones and one an abandoned collect left behind both stay' do
        collected = nil
        Cache::Failure.collect do
          run_once do
            abandoned = Enumerator.new { |out| Cache::Failure.collect { out << :paused } }
            abandoned.next
          end
          collected = ExecutionState[Cache::Failure::COLLECT_KEY].dup
        end

        assert_equal 2, collected.size, 'the end of a run never empties a collect still open (that would fail open)'
        assert_equal 1, ExecutionState[Cache::Failure::COLLECT_KEY].size, 'only the abandoned one is left'
      end

      test 'abandoned collects are bounded: the oldest go, and a collect past its payload bound confirms nobody' do
        (Cache::Failure::MAX_OPEN_COLLECTS + 5).times do
          Enumerator.new { |out| Cache::Failure.collect { out << :paused } }.next
        end

        assert_equal Cache::Failure::MAX_OPEN_COLLECTS, ExecutionState[Cache::Failure::COLLECT_KEY].size

        collected = Cache::Failure::Collected.new
        (Cache::Failure::Collected::MAX_PAYLOADS + 1).times { |i| collected << { user_id: i } }

        assert_equal Cache::Failure::Collected::MAX_PAYLOADS, collected.to_a.size
        assert_empty collected.confirmed([9_999_999]), 'past the bound it confirms nobody (fails closed)'
      end

      test 'a request run starts and ends with an empty audit context: there cleaning is clearing' do
        run_once do
          ExecutionState[:pf_audit_context] = { source: 'admin_ui' }.freeze # left set: no block put it back
          ExecutionState[:pf_audit_runtime_once] = { %w[rule.bypassed x] => true }
          ExecutionState[:pf_audit_transaction_correlation] = [Object.new, 'id']
        end
        run_once do
          assert_equal({}, Audit::Context.current)
          assert_nil ExecutionState[:pf_audit_runtime_once]
          assert_nil ExecutionState[:pf_audit_transaction_correlation]
        end
      end

      test 'with_audit_actor around an executor run (an inline job) keeps its actor after the run' do
        PermissionForge.with_audit_actor(label: 'ops@acme', source: 'rake') do
          run_once { Audit::Context.with(source: 'job') { assert_equal 'ops@acme', Audit::Context[:actor].label } }
          create_permission_set(name: 'After the job')
        end

        assert_audit_event('permission_set.created', actor_label: 'ops@acme', source: 'rake')
        assert_equal({}, Audit::Context.current)
      end

      test 'the failure count outlives a run: none? around a run still sees a failure in it' do
        previous = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(StringIO.new)
        assert_not(Cache::Failure.none? { run_once { Cache::Failure.report(operation: :invalidate) } })
      ensure
        Rails.logger = previous
      end

      test 'a run completed on another thread than it started on cleans nothing there' do
        snapshot = ExecutionState::RunHook.run
        ExecutionState[:pf_inspecting] = :left
        ExecutionState[:pf_open_invalidation_batch] = :left
        Thread.new { ExecutionState::RunHook.complete(snapshot) }.join
        assert_equal %i[left left], [ExecutionState[:pf_inspecting], ExecutionState[:pf_open_invalidation_batch]]

        ExecutionState::RunHook.complete(snapshot)
        assert_equal [nil, nil], [ExecutionState[:pf_inspecting], ExecutionState[:pf_open_invalidation_batch]]
      end

      test 'a run completed in another fiber of its thread cleans only the execution slots' do
        skip 'needs thread isolation' unless ExecutionStateTest.thread_isolation?

        snapshot = ExecutionState::RunHook.run
        ExecutionState[:pf_inspecting] = :left
        ExecutionState[:pf_open_invalidation_batch] = :left
        Fiber.new { ExecutionState::RunHook.complete(snapshot) }.resume

        assert_equal [:left, nil], [ExecutionState[:pf_inspecting], ExecutionState[:pf_open_invalidation_batch]]
      end
    end
    # --- a request through ActionDispatch::Executor, as a server serves it ------------------------

    # ActionDispatch::Executor completes the run when the server closes the
    # body (or, on Rails 8.1+, in rack.response_finished): after every
    # middleware above it has returned. A host middleware there that wraps the
    # call in a gem block has ended that block before the run completes.
    class RequestTest < ActiveSupport::TestCase
      # Serves one request as a server does: call, iterate, close, then the
      # rack.response_finished callbacks.
      def serve(app, finished:)
        env = Rack::MockRequest.env_for('/')
        env['rack.response_finished'] = [] if finished
        _status, _headers, body = app.call(env)
        body.each { |_chunk| nil }
        body.close if body.respond_to?(:close)
        env['rack.response_finished']&.each { |callback| callback.call(env, 200, {}, nil) }
      end

      def executor(app)
        ActionDispatch::Executor.new(app, Rails.application.executor)
      end

      def state
        { suspended: PermissionForge.scope_suspended?, context: Audit::Context.current }
      end

      WRAPPERS = {
        'without_permission_scope' => ->(&body) { PermissionForge.without_permission_scope(&body) },
        'Audit::Context.with' => ->(&body) { Audit::Context.with(reason: 'middleware', request_id: 'req-1', &body) },
        'with_audit_actor' => ->(&body) { PermissionForge.with_audit_actor(label: 'ops@acme', &body) }
      }.freeze

      [false, true].each do |finished|
        WRAPPERS.each do |label, wrapper|
          test "a middleware above the Executor wrapping the call in #{label} leaves nothing on the thread " \
               "(#{finished ? 'rack.response_finished' : 'body.close'})" do
            seen = []
            app = executor(lambda { |_env|
              seen << state
              [200, {}, ['ok']]
            })
            above = ->(env) { wrapper.call { app.call(env) } }

            after = Thread.new do
              serve(above, finished: finished)
              left = state
              serve(app, finished: finished)
              left
            end.value

            assert_equal({ suspended: false, context: {} }, after, 'the thread after the first request')
            assert_equal({ suspended: false, context: {} }, seen.last, 'the next request on the thread')
          end
        end
      end

      test 'a request served inside an open run completes that run: the block around it is scoped again (fails closed)' do
        seen = []
        app = executor(lambda { |_env|
          seen << PermissionForge.scope_suspended?
          [200, {}, ['ok']]
        })
        Thread.new do
          Rails.application.executor.wrap do
            PermissionForge.without_permission_scope do
              serve(app, finished: false) # run!(reset: true) completes the outer run, which started without the flag
              seen << PermissionForge.scope_suspended?
            end
          end
        end.join

        assert_equal [false, false], seen
      end

      test 'the next request on the thread is scoped again (Level 1, a rule that allows 1 of 2 rows)' do
        PermissionForge.configuration.auto_query_scoping = :filter_only
        user = create_user
        set = create_permission_set
        create_permission_set_user(user: user, permission_set: set)
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        create_permission_set_rule(permission_set: set, resource: resource, field_name: 'name', field_value: 'Mine',
                                   operator: 'equal', include_nulls: false)
        create_customer(name: 'Mine')
        create_customer(name: 'Not mine')

        counts = []
        app = executor(lambda { |_env|
          Current.user = user
          counts << Customer.count
          [200, {}, ['ok']]
        })
        above = ->(env) { PermissionForge.without_permission_scope { app.call(env) } }
        [above, app, app].each { |stack| serve(stack, finished: false) }

        assert_equal [2, 1, 1], counts
      end
    end
  end
end
