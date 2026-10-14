# frozen_string_literal: true

require 'test_helper'
require 'rake'
require 'active_job'

ActiveJob::Base.logger = Rails.logger

# A host job that changes a permission model (the dummy app does not load
# ActiveJob; the engine's on_load hook applies when it is first loaded).
class PfAuditRenameJob < ActiveJob::Base
  def perform(set_id, name, admin_id = nil)
    rename = -> { PermissionForge::PermissionSet.find(set_id).update!(name: name) }
    return rename.call unless admin_id

    PermissionForge.with_audit_actor(user: User.find(admin_id)) { rename.call }
  end
end

module PermissionForge
  module Audit
    # The rest of the actor matrix — job, rake, console, nothing — and the
    # created_by / updated_by stamps of HasAuditTrail.
    class ActorSourcesTest < ActiveSupport::TestCase
      setup do
        @set = create_permission_set(name: 'Sales rep')
        @admin = create_user(name: 'Ada Admin')
        @old_resolver = PermissionForge.configuration.current_user_resolver
        @old_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :inline
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
        ActiveJob::Base.queue_adapter = @old_adapter
      end

      # ---- jobs ------------------------------------------------------------------------

      test 'a job records source job; with nobody named the actor is unknown' do
        PfAuditRenameJob.perform_now(@set.id, 'By job')

        assert_audit_event('permission_set.updated', source: 'job', actor_type: 'unknown', actor_id: nil, record_id: @set.id.to_s)
      end

      test 'a job that names its actor records that user, source job' do
        PfAuditRenameJob.perform_now(@set.id, 'By job', @admin.id)

        assert_audit_event('permission_set.updated', source: 'job', actor_type: 'user', actor_id: @admin.id.to_s,
                                                     actor_label: 'Ada Admin')
      end

      test 'a job run by a queue adapter (perform_later) records source job' do
        # acts_as_tenant serializes the ambient tenant through GlobalID, which the dummy app does not load
        ActsAsTenant.test_tenant = nil
        ActsAsTenant.with_tenant(nil) { PfAuditRenameJob.perform_later(@set.id, 'Queued') }

        assert_audit_event('permission_set.updated', source: 'job', data: { 'changes' => { 'name' => ['Sales rep', 'Queued'] } })
      end

      test 'the job context is gone after the job, also after a failing job' do
        PfAuditRenameJob.perform_now(@set.id, 'By job')
        assert_equal({}, Context.current)

        assert_raises(ActiveRecord::RecordNotFound) { PfAuditRenameJob.perform_now(0, 'x') }
        assert_equal({}, Context.current)
      end

      test 'a job performed inside an admin request keeps the admin and says job' do
        Context.with(actor: @admin, source: 'admin_ui', request_id: 'req-j') { PfAuditRenameJob.perform_now(@set.id, 'Inline') }

        assert_audit_event('permission_set.updated', source: 'job', actor_id: @admin.id.to_s, request_id: 'req-j')
      end

      # ---- rake, console, none ---------------------------------------------------------

      test 'a rake task records source rake; ACTOR-style labels come from with_audit_actor' do
        with_rake_tasks(['permission_forge:cleanup']) do
          @set.update!(name: 'By rake')
          PermissionForge.with_audit_actor(label: 'ops@acme') { @set.update!(name: 'By rake, named') }
        end

        assert_audit_event('permission_set.updated', source: 'rake', actor_type: 'unknown',
                                                     data: { 'changes' => { 'name' => ['Sales rep', 'By rake'] } })
        assert_audit_event('permission_set.updated', source: 'rake', actor_type: 'system', actor_label: 'ops@acme', actor_id: nil)
      end

      test 'a console records source console and the user it is told about' do
        with_console do
          PermissionForge.configuration.current_user_resolver = -> { @admin }
          @set.update!(name: 'By console')
        end

        assert_audit_event('permission_set.updated', source: 'console', actor_type: 'user', actor_id: @admin.id.to_s)
      end

      test 'nothing at all: source service, actor unknown' do
        @set.update!(name: 'Plain')

        assert_audit_event('permission_set.updated', source: 'service', actor_type: 'unknown', actor_id: nil, actor_label: nil)
      end

      # ---- HasAuditTrail ---------------------------------------------------------------

      test 'create stamps created_by and updated_by with the acting user' do
        with_audit_trail do
          PermissionForge.configuration.current_user_resolver = -> { @admin }
          set = create_permission_set(name: 'Fresh')

          assert_equal [@admin.id, @admin.id], [set.created_by_id, set.updated_by_id]
        end
      end

      test 'create with an explicit creator and nobody acting stamps updated_by with the creator' do
        with_audit_trail do
          set = create_permission_set(name: 'Fresh', created_by_id: @admin.id)

          assert_equal @admin.id, set.updated_by_id
        end
      end

      test 'an edit with no acting user keeps the previous updated_by' do
        with_audit_trail do
          PermissionForge.configuration.current_user_resolver = -> { @admin }
          set = create_permission_set(name: 'Fresh')
          PermissionForge.configuration.current_user_resolver = -> {}

          set.update!(name: 'Edited by nobody')

          assert_equal @admin.id, set.reload.updated_by_id
        end
      end

      test 'an edit by another user moves updated_by; an edit under Basic auth or an API client keeps it' do
        with_audit_trail do
          other = create_user(name: 'Bo')
          PermissionForge.configuration.current_user_resolver = -> { @admin }
          set = create_permission_set(name: 'Fresh')

          PermissionForge.with_audit_actor(user: other) { set.update!(name: 'By Bo') }
          assert_equal other.id, set.reload.updated_by_id

          PermissionForge.configuration.current_user_resolver = -> {}
          Context.with(actor: { type: 'basic_auth', label: 'ops-admin' }) { set.update!(name: 'By Basic') }
          Context.with(actor: { type: 'api', label: 'API client' }) { set.update!(name: 'By API') }
          assert_equal other.id, set.reload.updated_by_id
          assert_equal @admin.id, set.created_by_id
        end
      end

      test 'the audit actor of a job stamps the record' do
        with_audit_trail do
          PfAuditRenameJob.perform_now(@set.id, 'By job', @admin.id)

          assert_equal @admin.id, @set.reload.updated_by_id
        end
      end

      test 'an admin of another model stamps nothing: its id would name a different User' do
        with_audit_trail do
          foreign_admin = Struct.new(:id, :name).new(@admin.id, 'Ops Admin (AdminUser table)')
          set = create_permission_set(name: 'Fresh')

          Context.with(actor: foreign_admin) { set.update!(name: 'By foreign admin') }

          assert_nil set.reload.updated_by_id
          assert_audit_event('permission_set.updated', actor_type: 'user', actor_id: @admin.id.to_s,
                                                       data: { 'changes' => { 'name' => ['Fresh', 'By foreign admin'] } })
        end
      end

      test 'a decorated current user (SimpleDelegator) still stamps: the class is the wrapped record' do
        with_audit_trail do
          decorated = SimpleDelegator.new(@admin)
          PermissionForge.configuration.current_user_resolver = -> { decorated }
          set = create_permission_set(name: 'Fresh')
          set.update!(name: 'By decorated admin')

          assert_equal [@admin.id, @admin.id], [set.created_by_id, set.reload.updated_by_id]
        end
      end

      test 'an actor given as a Hash or an Actor stamps nothing, whatever its id' do
        with_audit_trail do
          PermissionForge.configuration.current_user_resolver = -> { @admin }
          set = create_permission_set(name: 'Fresh')

          Context.with(actor: { type: 'user', id: 'tok-9', label: 'Token' }) { set.update!(name: 'By token') }
          Context.with(actor: Actor.new(type: 'user', id: @admin.id + 1000, label: 'Hand made')) { set.update!(name: 'By hand') }

          assert_equal @admin.id, set.reload.updated_by_id
        end
      end

      private

      def with_audit_trail
        PermissionForge.configuration.audit_trail_enabled = true
        yield
      ensure
        PermissionForge.configuration.audit_trail_enabled = false
      end

      def with_rake_tasks(tasks)
        previous = Rake.application.top_level_tasks.dup
        Rake.application.top_level_tasks.replace(tasks)
        yield
      ensure
        Rake.application.top_level_tasks.replace(previous)
      end

      def with_console
        defined_here = !defined?(::Rails::Console)
        ::Rails.const_set(:Console, Class.new) if defined_here
        yield
      ensure
        ::Rails.send(:remove_const, :Console) if defined_here && defined?(::Rails::Console)
      end
    end
  end
end
