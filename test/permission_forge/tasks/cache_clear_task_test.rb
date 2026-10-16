# frozen_string_literal: true

require 'test_helper'
require 'rake'

module PermissionForge
  # `rake permission_forge:cache:clear`: the deploy step after a release that
  # changed the cache entries — a data-changing task (ACTOR=, REASON=), one
  # `cache.cleared` event.
  class CacheClearTaskTest < ActiveSupport::TestCase
    # Loaded once per process (reloading resets the file's coverage counters).
    def self.rake_application
      @rake_application ||= begin
        previous = Rake.application
        app = Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)
        load PermissionForge::Engine.root.join('lib/tasks/permission_forge_cache.rake').to_s
        Rake.application = previous
        app
      end
    end

    setup do
      @previous_rake = Rake.application
      Rake.application = self.class.rake_application
      Rake.application.tasks.each(&:reenable)
      @saved_env = ENV.to_h.slice('ACTOR', 'REASON')
      %w[ACTOR REASON].each { |key| ENV.delete(key) }
      @user = create_user(name: 'Rae Rake')
      set = create_permission_set(name: 'Rake Set')
      create_permission_set_user(user: @user, permission_set: set)
      create_resource(permission_set: set, name: 'Customer', read_access: true)
      User.find(@user.id).permissions_hash
    end

    teardown do
      Rake.application = @previous_rake
      %w[ACTOR REASON].each { |key| ENV.delete(key) }
      @saved_env.each { |key, value| ENV[key] = value }
    end

    test 'with ACTOR and REASON: every holder is invalidated, the event names the actor from rake' do
      ENV['ACTOR'] = 'ops: TCK-12'
      ENV['REASON'] = 'deploy 0.14'

      out, err = capture_io { Rake::Task['permission_forge:cache:clear'].invoke }

      assert_empty err
      assert_match(/\ARemoved every cached permission hash by key pattern:\n/, out)
      assert_includes out, "Cached permissions removed: #{PermissionForge::RakeOutput::CONFIRMED_HERE}"
      assert_not_includes out, 'The cache is cold', 'one outcome, one message: the scope line says what it means'
      assert_nil PermissionForge.cache.read(@user.permission_cache_key)
      assert_audit_event('cache.cleared', actor_type: 'system', actor_label: 'ops: TCK-12', source: 'rake', reason: 'deploy 0.14',
                                          data: { 'strategy' => 'pattern', 'unconfirmed' => 0 })
      column = PermissionForge::AuditEvent.tenant_column
      tenantless = PermissionForge::AuditEvent.unscoped.where(event: 'cache.cleared').to_a.find { |event| event.read_attribute(column).nil? }
      assert_equal true, tenantless.data['across_tenants'], 'the event without a tenant, with the totals'
    end

    # Packaging pre-release review N11 (PKG-N11): on a per-process store the
    # task said it removed everything, but only its own store was emptied.
    # The scope line is the one Cache::Outcome every cache-touching task
    # prints (RakeOutput).
    test 'PKG-N11 on a per-process store it says that only its own store was cleared' do
      scope = "Cache scope: #{PermissionForge::RakeOutput::PROCESS_LOCAL_NOTE}"
      out, = capture_io { Rake::Task['permission_forge:cache:clear'].invoke }
      assert_includes out, scope

      PermissionForge.configuration.cache_backend = ActiveSupport::Cache::MemoryStore.new
      PermissionForge.configuration.reset_cache_store!
      Rake::Task['permission_forge:cache:clear'].reenable
      out, = capture_io { Rake::Task['permission_forge:cache:clear'].invoke }
      assert_includes out, scope, ':memory_store'

      directory = Dir.mktmpdir
      PermissionForge.configuration.cache_backend = ActiveSupport::Cache::FileStore.new(directory)
      PermissionForge.configuration.reset_cache_store!
      Rake::Task['permission_forge:cache:clear'].reenable
      out, = capture_io { Rake::Task['permission_forge:cache:clear'].invoke }
      assert_includes out, "Cache scope: #{PermissionForge::RakeOutput::SHARED_NOTE}", 'a store the processes share'
      assert_not_includes out, 'this process only'
    ensure
      PermissionForge.configuration.cache_backend = :memory
      PermissionForge.configuration.reset_cache_store!
      FileUtils.rm_rf(directory) if directory
    end

    test 'without ACTOR it warns and records the task as the actor' do
      _, err = capture_io { Rake::Task['permission_forge:cache:clear'].invoke }

      assert_match(/ACTOR is not set/, err)
      assert_audit_event('cache.cleared', actor_label: 'rake permission_forge:cache:clear')
      assert User.find(@user.id).can_read?(:Customer), 'rebuilt on the next read'
    end
  end
end
