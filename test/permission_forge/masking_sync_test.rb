require 'test_helper'
require_relative '../support/boot_test_helpers'
# loaded with the file, not in a test: it creates tables, and DDL commits the
# fixture transaction on MySQL
require_relative 'masked_alias_models'

module PermissionForge
  # What the MaskingSync tests share: probe models, and "another process".
  module MaskingSyncTestHelpers
    LATE_TABLE = 'pf_masking_sync_late_rows'.freeze

    private

    # A model class this process has not masked (Customer's table), under a
    # name of its own so no other test's class is touched.
    def fresh_model(name = :"PfMaskingSyncProbe#{SecureRandom.hex(4)}", table = 'customers')
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
      Object.const_set(name, Class.new(ActiveRecord::Base) { self.table_name = table })
    end

    def applied?(klass)
      PermissionForge::Concerns::MaskedAttributes.applied?(klass)
    end

    # What another process does: commits the row (here without masking the
    # class in this process) and, by default, writes a new token.
    def named_elsewhere(klass, announce: true)
      PermissionForge.configuration.auto_apply_masked_attributes = false
      create_resource(permission_set: create_permission_set(name: "Set for #{klass.name}"), name: klass.name)
      PermissionForge.configuration.auto_apply_masked_attributes = :auto
      PermissionForge.cache.write(MaskingSync::KEY, SecureRandom.uuid) if announce
    end

    def count_store_reads
      cache = PermissionForge.cache
      reads = 0
      counting = Module.new do
        define_method(:read) { |key| (reads += 1) && super(key) } # read_fresh reads through it
      end
      cache.singleton_class.prepend(counting)
      yield
      reads
    ensure
      counting.send(:remove_method, :read)
    end
  end

  # Auto-applied masking used to reach only the process that committed the
  # first Resource row for a model: every other worker served the model's
  # columns unmasked until it restarted. Here "another process" is this one
  # with a model class it has not masked yet while the row exists and the
  # shared store says a model was named since it last synced.
  class MaskingSyncTest < ActiveSupport::TestCase
    include BootTestHelpers
    include MaskingSyncTestHelpers

    setup do
      @model = fresh_model
      MaskingSync.reset!
      MaskingSync.boot!
    end

    teardown do
      MaskingSync.reset!
      MaskingSync.boot!
    end

    test 'a model named in another process is masked at the next request or job of this one' do
      named_elsewhere(@model)
      refute applied?(@model)

      Rails.application.executor.wrap { nil } # a request or a job

      assert applied?(@model)
    end

    test 'when nothing was named the check is one store read and no query' do
      reads = count_store_reads do
        @queries = count_sql { Rails.application.executor.wrap { nil } }
      end

      assert_equal 1, reads
      assert_equal 0, @queries
    end

    test 'nothing is read while auto-apply and virtual masking are off' do
      PermissionForge.configuration.auto_apply_masked_attributes = false

      assert_equal(0, count_store_reads { MaskingSync.check! })
    end

    test 'committing the first row for a model masks it here and tells the other processes' do
      before = PermissionForge.cache.read(MaskingSync::KEY)

      create_resource(permission_set: create_permission_set, name: @model.name)

      assert applied?(@model)
      refute_equal before, PermissionForge.cache.read(MaskingSync::KEY)
    end

    test 'another row for a model already named does not write a new token' do
      create_resource(permission_set: create_permission_set, name: @model.name)
      token = PermissionForge.cache.read(MaskingSync::KEY)

      create_resource(permission_set: create_permission_set(name: 'Second'), name: @model.name)

      assert_equal token, PermissionForge.cache.read(MaskingSync::KEY)
    end

    test 'renaming a row to a new model announces that model' do
      resource = create_resource(permission_set: create_permission_set, name: 'Supplier')
      token = PermissionForge.cache.read(MaskingSync::KEY)

      resource.update!(name: @model.name)

      assert applied?(@model)
      refute_equal token, PermissionForge.cache.read(MaskingSync::KEY)
    end

    test 'a row rolled back announces nothing' do
      token = 'before'
      PermissionForge.cache.write(MaskingSync::KEY, token)

      ActiveRecord::Base.transaction do
        create_resource(permission_set: create_permission_set, name: @model.name)
        raise ActiveRecord::Rollback
      end

      refute applied?(@model)
      assert_equal token, PermissionForge.cache.read(MaskingSync::KEY)
    end

    # The boot could not reach the database: the first request or job that
    # can applies, whatever the token says.
    test 'a process that has not synced applies at its first run' do
      named_elsewhere(@model, announce: false)
      MaskingSync.reset!

      Rails.application.executor.wrap { nil }

      assert applied?(@model)
      assert_predicate MaskingSync, :synced?
    end

    test 'a run that cannot read the Resource rows stays unsynced and tries again' do
      MaskingSync.reset!
      broken = -> { raise ActiveRecord::ConnectionNotEstablished, 'down' }

      with_singleton_method(PermissionForge::Resource, :table_exists?, broken) { MaskingSync.check! }

      refute_predicate MaskingSync, :synced?
      MaskingSync.check!
      assert_predicate MaskingSync, :synced?
    end

    test 'a failing sync never breaks the request' do
      named_elsewhere(@model)
      exploding = ->(*) { raise ArgumentError, 'boom' }

      log = capture_rails_log do
        with_singleton_method(PermissionForge::MaskedModels, :apply, exploding) do
          assert_nothing_raised { Rails.application.executor.wrap { nil } }
        end
      end

      assert_match(/auto-applied masking could not be synced — ArgumentError: boom/, log)
    end

    # Development: a code reload hands out new, unmasked model classes.
    test 'after a code reload the models are masked again' do
      create_resource(permission_set: create_permission_set, name: @model.name)
      reloaded = fresh_model(@model.name.to_sym)
      refute applied?(reloaded)

      MaskingSync.reloaded!

      assert applied?(reloaded)
    end

    test 'the warning for a model that cannot be masked is logged once per process' do
      late = fresh_model(:PfMaskingSyncLate, LATE_TABLE)
      named_elsewhere(late, announce: false)
      MaskingSync.reset!

      log = capture_rails_log { 3.times { Rails.application.executor.wrap { nil } } }

      assert_equal 1, log.scan('PfMaskingSyncLate has a Resource row').size
    end

    test 'a boot that could not mask every model says so' do
      late = fresh_model(:PfMaskingSyncLate, LATE_TABLE)
      named_elsewhere(late, announce: false)
      MaskingSync.reset!

      log = capture_rails_log { refute MaskingSync.boot! }

      assert_match(/Auto-applied masking is not complete at boot/, log)
    end

    # The token is last-writer-wins: another process may have written one
    # between this process's last check and its own announcement.
    test 'announcing a model does not hide a model another process named meanwhile' do
      other = fresh_model
      Rails.application.executor.wrap { nil } # in step with the store
      named_elsewhere(other) # another process names `other` and writes a token

      create_resource(permission_set: create_permission_set(name: 'Ours'), name: @model.name) # we announce ours
      Rails.application.executor.wrap { nil }

      assert applied?(@model)
      assert applied?(other)
    end

    # The boot could not reach the database, the first request synced: a
    # development reload must still re-apply.
    test 'after a boot without the database a code reload still re-applies' do
      MaskingSync.reset! # what a boot without the database leaves
      named_elsewhere(@model)
      Rails.application.executor.wrap { nil }
      reloaded = fresh_model(@model.name.to_sym)

      MaskingSync.reloaded!

      assert applied?(reloaded)
    end

    # A subclass is masked through its parent (the concern is never included
    # into a subclass), and may have a Resource row of its own (STI). It is
    # not a model "left halfway": no warning, and the process is in step.
    test 'a subclass of a masked model with its own Resource row is in step and not reported' do
      child = Object.const_set(:"#{@model.name}Child", Class.new(@model))
      create_resource(permission_set: create_permission_set(name: 'Parent'), name: @model.name)
      named_elsewhere(child)
      MaskingSync.reset!

      log = capture_rails_log { Rails.application.executor.wrap { nil } }

      assert_predicate MaskingSync, :synced?
      assert_no_match(/SECURITY warning/, log)
      assert_equal 0, count_sql { Rails.application.executor.wrap { nil } }, 'in step: no query on the next run'
    ensure
      Object.send(:remove_const, :"#{@model.name}Child") if Object.const_defined?(:"#{@model.name}Child", false)
    end

    # The suite's alias and STI fixtures: parents masked, subclasses with rows
    # of their own. None of them may be reported as a failed include.
    test 'the alias and subclass fixtures are never reported as half-included' do
      subclasses = [PfAliasChild, PfAliasLateChild, PfAliasRedeclaredChild, PfCar, PfPickup]
      PermissionForge.configuration.auto_apply_masked_attributes = false
      subclasses.each_with_index do |klass, i|
        create_resource(permission_set: create_permission_set(name: "Fixture #{i}"), name: klass.superclass.name)
        create_resource(permission_set: create_permission_set(name: "Fixture child #{i}"), name: klass.name)
      end
      PermissionForge.configuration.auto_apply_masked_attributes = :auto
      subclasses.each { |klass| PermissionForge::MaskedModels.apply_concern(klass.superclass.name) }
      MaskingSync.reset!

      log = capture_rails_log { assert MaskingSync.boot! }

      assert_no_match(/failed halfway/, log)
    end

    # The concern is applied while the per-model loop runs: an error that
    # means the configuration is wrong still stops the boot.
    test 'a ConfigurationError while masking a model is raised, not logged' do
      named_elsewhere(@model, announce: false)
      MaskingSync.reset!
      misconfigured = ->(_name) { raise PermissionForge::ConfigurationError, 'bad setting' }

      with_singleton_method(PermissionForge::MaskedModels, :apply_concern, misconfigured) do
        assert_raises(PermissionForge::ConfigurationError) { MaskingSync.boot! }
      end
    end
  end

  # Masking applied explicitly: the models are a list in the configuration
  # (or the concern is included by the models and auto-apply is off). No
  # Resource row can name a model the list does not, so no token is read or
  # written, and a process that has synced does nothing per request.
  class MaskingSyncListedModelsTest < ActiveSupport::TestCase
    include BootTestHelpers
    include MaskingSyncTestHelpers

    setup do
      @model = fresh_model
      PermissionForge.configuration.auto_apply_masked_attributes = [@model.name]
      MaskingSync.reset!
    end

    teardown do
      PermissionForge.configuration.auto_apply_masked_attributes = :auto
      MaskingSync.reset!
      MaskingSync.boot!
    end

    test 'a process that has synced reads nothing at a request or job' do
      assert MaskingSync.boot!
      assert applied?(@model), 'a listed model is masked at boot, Resource row or not'

      reads = count_store_reads { @queries = count_sql { Rails.application.executor.wrap { nil } } }

      assert_equal 0, reads
      assert_equal 0, @queries
    end

    # Its boot could not reach the database.
    test 'a process that has not synced masks the listed models at its next run, without the store' do
      reads = count_store_reads { Rails.application.executor.wrap { nil } }

      assert applied?(@model)
      assert_predicate MaskingSync, :synced?
      assert_equal 0, reads
    end

    test 'the first row for a listed model is masked here and writes no token' do
      PermissionForge.cache.write(MaskingSync::KEY, 'before')

      create_resource(permission_set: create_permission_set, name: @model.name)

      assert applied?(@model)
      assert_equal 'before', PermissionForge.cache.read(MaskingSync::KEY)
    end

    test 'after a code reload the listed models are masked again' do
      MaskingSync.boot!
      reloaded = fresh_model(@model.name.to_sym)

      MaskingSync.reloaded!

      assert applied?(reloaded)
    end

    test 'a virtual-reader list alone reads nothing either' do
      PermissionForge.configuration.auto_apply_masked_attributes = false
      PermissionForge.configuration.mask_virtual_attributes = [@model.name]
      MaskingSync.boot!

      assert_equal(0, count_store_reads { Rails.application.executor.wrap { nil } })
    end

    test 'a row-driven setting next to a list still reads the token' do
      PermissionForge.configuration.mask_virtual_attributes = :auto
      MaskingSync.boot!

      assert_equal(1, count_store_reads { Rails.application.executor.wrap { nil } })
    end

    # A typo, or a class not loaded yet: never counted as masked.
    test 'a listed name that is no model is logged once and tried again at the next run' do
      PermissionForge.configuration.auto_apply_masked_attributes = [@model.name, 'PfMaskingSyncListedLater']

      log = capture_rails_log { 3.times { Rails.application.executor.wrap { nil } } }

      assert applied?(@model), 'the other listed models are masked'
      refute_predicate MaskingSync, :synced?
      assert_equal 1, log.scan("'PfMaskingSyncListedLater' is listed in config.auto_apply_masked_attributes").size, log
      later = fresh_model(:PfMaskingSyncListedLater)
      Rails.application.executor.wrap { nil }

      assert applied?(later)
      assert_predicate MaskingSync, :synced?
    ensure
      Object.send(:remove_const, :PfMaskingSyncListedLater) if Object.const_defined?(:PfMaskingSyncListedLater, false)
    end

    test 'with both settings off a request or job reads nothing and runs no query' do
      PermissionForge.configuration.auto_apply_masked_attributes = false
      MaskingSync.boot!

      reads = count_store_reads { @queries = count_sql { Rails.application.executor.wrap { nil } } }

      assert_equal 0, reads
      assert_equal 0, @queries
    end
  end

  # A store that cannot carry the token to another process: one that lives in
  # each process (:memory, a :memory_store — Rails 8's development default) or
  # keeps nothing (:null, a :null_store — Rails 7.1/7.2's). Field test: a
  # Customer Resource row created from `bin/rails runner` never reached the
  # running server, whose pages showed the emails in clear until a restart.
  class MaskingSyncUnsharedStoreTest < ActiveSupport::TestCase
    include BootTestHelpers
    include MaskingSyncTestHelpers

    setup do
      @model = fresh_model
      @clock = [1_000.0] # monotonic seconds (on_clock)
    end

    teardown do
      use_backend(:memory)
      MaskingSync.reset!
      MaskingSync.boot!
    end

    test 'development with a per-process store masks a model named from another process at the next request' do
      in_rails_env('development') do
        booted
        named_elsewhere(@model, announce: false) # the runner's own store: nothing reaches this one

        Rails.application.executor.wrap { nil }

        assert applied?(@model)
      end
    end

    test 'development re-reads the Resource names at most every DATABASE_RECHECK seconds' do
      in_rails_env('development') do
        on_clock do
          booted
          Rails.application.executor.wrap { nil }
          named_elsewhere(@model, announce: false)

          assert_equal 0, count_sql { Rails.application.executor.wrap { nil } }, 'within the interval: no query'
          refute applied?(@model)

          @clock[0] += MaskingSync::DATABASE_RECHECK
          assert_equal 1, count_sql { Rails.application.executor.wrap { nil } }, 'one query for the names'
          assert applied?(@model)
        end
      end
    end

    test 'development with a store that keeps nothing re-reads the names too, and asks it for no token' do
      use_backend(:null)
      in_rails_env('development') do
        booted
        named_elsewhere(@model, announce: false)

        log = capture_rails_log { assert_equal(0, count_store_reads { Rails.application.executor.wrap { nil } }) }

        assert applied?(@model)
        assert_no_match(/masking token/, log)
      end
    end

    # The per-request cost stays what it was outside development: no query.
    test 'production with a per-process store runs no query per request' do
      in_rails_env('production') do
        booted

        assert_equal(0, count_sql { Rails.application.executor.wrap { nil } })
      end
    end

    # Rails 7.1's development default: the boot logged "did not give or keep
    # the masking token" with no cause and no remedy.
    test 'a store that keeps nothing is asked for no token and logs no token warning' do
      use_backend(:null)

      log = capture_rails_log do
        assert booted
        assert_equal(0, count_store_reads { 3.times { Rails.application.executor.wrap { nil } } })
      end

      assert_no_match(/masking token/, log)
      assert_predicate MaskingSync, :synced?
      assert_equal 0, count_sql { Rails.application.executor.wrap { nil } }, 'in step: no query per request'
    end

    test 'with a store that keeps nothing the first row for a model is masked in the process that commits it' do
      use_backend(:null)
      booted

      create_resource(permission_set: create_permission_set, name: @model.name)

      assert applied?(@model)
    end

    private

    def booted
      MaskingSync.reset!
      MaskingSync.boot!
    end

    def use_backend(backend)
      PermissionForge.configuration.cache_backend = backend
      PermissionForge.configuration.reset_cache_store!
    end

    # MaskingSync's monotonic clock reads @clock for the block.
    def on_clock(&)
      clock = @clock
      with_singleton_method(MaskingSync, :now, -> { clock[0] }, &)
    end
  end

  # The migration that creates a model's table runs while the process is up.
  # DDL commits the open transaction on MySQL (its savepoints with it), so
  # this runs outside the fixture transaction and removes what it committed.
  class MaskingSyncLateTableTest < ActiveSupport::TestCase
    include BootTestHelpers
    include MaskingSyncTestHelpers

    self.use_transactional_tests = false

    setup do
      @audit_floor = AuditEvent.unscoped.maximum(:id).to_i
      @model = fresh_model
      MaskingSync.reset!
      MaskingSync.boot!
    end

    teardown do
      ActiveRecord::Base.connection.drop_table(LATE_TABLE, if_exists: true)
      sets = PermissionSet.unscoped.where(name: ['Set for PfMaskingSyncLate', "Set for #{@model.name}"])
      Resource.unscoped.where(permission_set_id: sets.select(:id)).delete_all
      sets.delete_all
      User.unscoped.where(id: @nobody&.id).delete_all
      AuditEvent.unscoped.where(id: (@audit_floor + 1)..).delete_all
      MaskingSync.reset!
      MaskingSync.boot!
    end

    # A Resource row seeded before its model's migration ran here (or a model
    # on a database that is down). Including the concern then failed halfway:
    # the module was in the ancestors, so every later include was a no-op,
    # the model stayed unmasked for good and the process said it was synced.
    test 'a model whose table is missing is skipped with a warning, the others are masked, and it is retried' do
      late = fresh_model(:PfMaskingSyncLate, LATE_TABLE)
      # the table-less model comes first in the pluck order
      named_elsewhere(late, announce: false)
      named_elsewhere(@model, announce: false)
      MaskingSync.reset!

      log = capture_rails_log { Rails.application.executor.wrap { nil } }

      assert applied?(@model), 'one broken model must not leave the others unmasked'
      refute applied?(late)
      refute late.include?(PermissionForge::Concerns::MaskedAttributes), 'never included halfway'
      assert_match(/SECURITY warning: PfMaskingSyncLate has a Resource row but its table cannot be read/, log)
      refute_predicate MaskingSync, :synced?, 'a model left unmasked is not in step'

      ActiveRecord::Base.connection.create_table(LATE_TABLE) { |t| t.string :email } # the migration runs
      record = late.create!(email: 'secret@example.test')
      Rails.application.executor.wrap { nil }

      assert applied?(late)
      assert_predicate MaskingSync, :synced?
      PermissionForge.configuration.unconfigured_field_strategy = :block # the shipped default
      @nobody = nobody = create_user(name: 'Nobody')
      PermissionForge.configuration.current_user_resolver = -> { nobody }
      refute_equal 'secret@example.test', late.find(record.id).email, 'a reader with no grants must not see the raw value'
    ensure
      PermissionForge.configuration.current_user_resolver = -> { Current.user }
    end
  end
end
