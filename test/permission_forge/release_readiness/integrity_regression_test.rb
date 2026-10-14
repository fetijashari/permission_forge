# frozen_string_literal: true

require 'test_helper'
require 'rake'
require_relative '../tenancy/tenancy_test_helper'
require_relative '../../support/declares_audit_user_class'

# A host whose admin/user table has no uuid column, as most Rails apps have
# (integrity B2). Made once per process, outside any test transaction.
ActiveRecord::Schema.define do
  create_table :pf_rr_admins, force: true do |t|
    t.string :name
    t.string :email
  end
end

class PfRrAdmin < ActiveRecord::Base
  self.table_name = 'pf_rr_admins'
end

# A model named by a Resource row that another process commits (integrity M2).
class PfRrLateInvoice < ApplicationRecord
  self.table_name = 'customers'
end

module PermissionForge
  module ReleaseReadiness
    # The pre-release review of 2026-10-12, integrity lane, plus the claims-lane findings about the GDPR services
    # (#2, #3). Data integrity, tenancy, the audit log and the GDPR services,
    # driven through the services, the models and the rake-backed paths a
    # host uses. B1 (boot without a database) is proved end to end by
    # shipped_defaults_regression_test.rb. Each test failed on v0.13.0
    # unless named as a limit.
    class IntegrityRegressionTest < ActiveSupport::TestCase
      include PermissionForge::Tenancy::TenancyTestHelper
      include DeclaresAuditUserClass

      setup do
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
      end

      teardown do
        declare_audit_user_class(@audit_user_class) if @audit_user_class
        ActsAsTenant.test_tenant = DEFAULT_TEST_ACCOUNT
      end

      def readable_customer_set(name: 'Readers')
        set = create_permission_set(name: name)
        create_resource(permission_set: set, name: 'Customer', read_access: true)
        set
      end

      def labelled_events_about(user, tenant)
        PermissionForge::AuditEvent.unscoped.where(subject_user_id: user.id.to_s, account_id: tenant.id).where.not(record_label: nil)
      end

      # ---- B2: a User model without a uuid column -----------------------------------

      # The shipped defaults stamp created_by_id when a signed-in admin
      # assigns a set. From then on, every permissions_hash build of the
      # holder raised NoMethodError (uuid) when the user model had no uuid
      # column: every can_*?, getter and find_by was a 500 for that user.
      test 'INT-B2 a holder granted by an admin without a uuid column still gets their permissions' do
        @audit_user_class = PermissionForge.configuration.audit_user_class
        PermissionForge.configuration.audit_trail_enabled = true
        declare_audit_user_class('PfRrAdmin')
        admin = PfRrAdmin.create!(name: 'Admin', email: 'admin@example.test')
        holder = create_user
        create_permission_set_user(user: holder, permission_set: readable_customer_set, created_by_id: admin.id, updated_by_id: admin.id)

        holder = User.find(holder.id)
        assert holder.can_read?(:Customer)
        source = holder.permissions_hash.dig(:permissions, :resources, :Customer, :source_permission_sets).sole
        assert_equal admin.id, source[:permission_set_granted_by], 'the grantor is named by id when there is no uuid'
      end

      # ---- M1: a tenant admin could erase a person out of every tenant ----------------

      # Erasure run with tenant A current (an admin's request) clears the
      # person's labels in tenant A's log only; tenant B's log and rows stay.
      test 'INT-M1 erasure with a tenant current scrubs that tenant only' do
        person = create_user(name: 'Bob Both-Tenants')
        assignment_b = within(@tenant_b) { create_permission_set_user(user: person, permission_set: readable_customer_set(name: 'B')) }
        within(@tenant_a) { create_permission_set_user(user: person, permission_set: readable_customer_set(name: 'A')) }
        assert_operator labelled_events_about(person, @tenant_b).count, :>, 0, 'the setup wrote labelled events in B'
        b_labels = labelled_events_about(person, @tenant_b).count

        result = within(@tenant_a) { PermissionForge::Services::DataSubjectErasure.call(user: person) }

        assert_equal 1, result[:assignments_removed]
        assert_equal 0, labelled_events_about(person, @tenant_a).count
        assert_equal b_labels, labelled_events_about(person, @tenant_b).count, "tenant B's log is not this admin's to scrub"
        within(@tenant_b) { assert PermissionForge::PermissionSetUser.exists?(assignment_b.id) }
        assert_equal 1, result[:assignments_remaining_elsewhere]
      end

      # ---- M2: masking switched on at runtime reached one process -----------------

      # Another process commits the first Resource row naming PfRrLateInvoice
      # and announces it in the shared store. This process never ran that
      # callback (the row is inserted behind its back); its next request or
      # job must pick the model up. The real two-process proof is in
      # shipped_defaults_regression_test.rb.
      test 'INT-M2 a model named by another process is masked here at the next executor run' do
        assert_not PermissionForge::Concerns::MaskedAttributes.applied?(PfRrLateInvoice)
        set = create_permission_set(name: 'Invoices')
        # test setup: the other process's row, committed behind this one's back
        PermissionForge::Resource.insert_all([{ uuid: SecureRandom.uuid, permission_set_id: set.id, name: 'PfRrLateInvoice',
                                                read_access: true, is_active: true, is_editable: true,
                                                account_id: DEFAULT_TEST_ACCOUNT.id, created_at: Time.current, updated_at: Time.current }])
        PermissionForge.cache.write('masked_models_version', SecureRandom.uuid) # what the other process announced
        assert_not PermissionForge::Concerns::MaskedAttributes.applied?(PfRrLateInvoice), 'nothing happened here yet'

        PermissionForge::MaskingSync.check! # what the executor runs at the start of each request or job

        assert PermissionForge::Concerns::MaskedAttributes.applied?(PfRrLateInvoice)
      end

      # ---- M3, documented limit: cache keys without acts_as_tenant ------------------

      # Only acts_as_tenant row tenancy is supported: with no current tenant
      # the key names the user alone, so schema- or database-per-tenant hosts
      # sharing a store must namespace it themselves (cache_key_prefix).
      test 'INT-M3 limit: the permission cache key is per tenant only under acts_as_tenant' do
        user = create_user

        within(@tenant_a) { assert user.permission_cache_key.end_with?("tenant_#{@tenant_a.id}_user_#{user.id}"), user.permission_cache_key }
        no_tenant!
        assert user.permission_cache_key.end_with?(":user_#{user.id}"), user.permission_cache_key
        assert_not_includes user.permission_cache_key, 'tenant_'
      end

      # ---- m1: an assignment moved to another user left the old holder cached ----

      test 'INT-m1 moving an assignment to another user revokes the previous holder at once' do
        from = create_user(name: 'From')
        to = create_user(name: 'To')
        assignment = create_permission_set_user(user: from, permission_set: readable_customer_set)
        assert User.find(from.id).can_read?(:Customer)

        assignment.update!(user: to)

        assert_not User.find(from.id).can_read?(:Customer), 'a fresh instance of the previous holder'
        assert User.find(to.id).can_read?(:Customer)
        event = audit_events_for(assignment).where(event: 'assignment.changed').last
        assert_equal to.id.to_s, event.subject_user_id
        assert_equal from.id.to_s, event.data['previous_subject_user_id']
      end

      # ---- m2: the cleaner deleted assignments renewed mid-run ------------------------

      test 'INT-m2 an assignment renewed while the cleaner runs survives it' do
        set = readable_customer_set
        gone = create_permission_set_user(user: create_user(name: 'Gone'), permission_set: set, expires_at: 2.hours.ago)
        renewed = create_permission_set_user(user: create_user(name: 'Renewed'), permission_set: set, expires_at: 1.hour.ago)
        after_first_delete { PermissionForge::PermissionSetUser.where(id: renewed.id).update_all(expires_at: 1.month.from_now) } # the admin's renewal

        result = PermissionForge::Services::ExpiredAssignmentCleaner.call

        assert_equal 1, result[:removed]
        assert_not PermissionForge::PermissionSetUser.exists?(gone.id)
        assert PermissionForge::PermissionSetUser.exists?(renewed.id), 'the renewed assignment must survive'
        assert_empty audit_events_for(renewed).where(event: 'assignment.revoked')
      end

      # ---- m3: destroying a user under one tenant orphaned the other tenants' rows ----

      test 'INT-m3 destroying a user while a tenant is current removes their rows in every tenant' do
        user = create_user(name: 'Leaving')
        within(@tenant_a) { create_permission_set_user(user: user, permission_set: readable_customer_set(name: 'A')) }
        assignment_b = within(@tenant_b) { create_permission_set_user(user: user, permission_set: readable_customer_set(name: 'B')) }

        within(@tenant_a) { user.destroy! }

        assert_empty PermissionForge::PermissionSetUser.unscoped.where(user_id: user.id), 'no orphan a reused id could inherit'
        revoked = PermissionForge::AuditEvent.unscoped.where(event: 'assignment.revoked', record_id: assignment_b.id.to_s).sole
        assert_equal @tenant_b.id, revoked.account_id, 'audited in the tenant of the row'
      end

      # ---- m4: a tenant-less purge left tenants without a record of it -------------

      test 'INT-m4 a purge with no tenant writes an audit.purged every tenant auditor can see' do
        now = Time.utc(2026, 6, 1, 12)
        within(@tenant_a) { 2.times { PermissionForge::Audit.record('report.generated', data: { 'task' => 'old' }, occurred_at: now - 1.year) } }
        within(@tenant_b) { PermissionForge::Audit.record('report.generated', data: { 'task' => 'old' }, occurred_at: now - 1.year) }
        no_tenant!

        result = PermissionForge::Services::AuditEventPurger.call(older_than: 90.days, now: now)

        assert_equal 3, result[:purged]
        assert_equal [2], within(@tenant_a) { PermissionForge::AuditEvent.where(event: 'audit.purged').map { |e| e.data['count'] } }
        assert_equal [[1, true]],
                     within(@tenant_b) { PermissionForge::AuditEvent.where(event: 'audit.purged').map { |e| e.data.values_at('count', 'across_tenants') } }
      end

      # ---- m5: cleanup.expired_assignments stored an unbounded id list ------------

      test 'INT-m5 the cleanup event stores a count and a bounded list of user ids' do
        limit = PermissionForge::Services::ExpiredAssignmentCleaner::AFFECTED_USER_IDS_LIMIT
        assert_operator limit, :<=, 100
        set = readable_customer_set
        domain = "expired-#{SecureRandom.hex(4)}.test"
        User.insert_all( # test setup
          Array.new(limit + 1) do |i|
            { uuid: SecureRandom.uuid, name: "Expired #{i}", email: "e#{i}@#{domain}", account_id: DEFAULT_TEST_ACCOUNT.id,
              created_at: Time.current, updated_at: Time.current }
          end
        )
        users = User.where('email LIKE ?', "%@#{domain}").pluck(:id) # read back: MySQL's insert_all returns no ids
        PermissionForge::PermissionSetUser.insert_all(users.map do |id| # test setup: rows that exist, not changes to audit
          { uuid: SecureRandom.uuid, permission_set_id: set.id, user_id: id, expires_at: 1.hour.ago, account_id: DEFAULT_TEST_ACCOUNT.id,
            created_at: Time.current, updated_at: Time.current }
        end)

        PermissionForge::Services::ExpiredAssignmentCleaner.call

        data = PermissionForge::AuditEvent.where(event: 'cleanup.expired_assignments').order(:id).last.data
        assert_equal limit + 1, data['affected_user_count']
        assert_equal limit, data['affected_user_ids'].size
        assert data['affected_user_ids_truncated']
        assert_operator data.to_json.bytesize, :<, 8_000
      end

      # ---- m6, documented limit: the Backlog keeps the last 500 owed invalidations ----

      # An outage during an edit to a set with more than LIMIT holders owes
      # one entry per holder; only the last LIMIT are kept (each failure was
      # reported through Cache::Failure) and cache_ttl is the backstop for
      # the rest. Documented in docs/architecture.md.
      test 'INT-m6 limit: the owed-invalidation backlog is capped and drops the oldest entries' do
        backlog = PermissionForge::Cache::Backlog.new
        limit = PermissionForge::Cache::Backlog::LIMIT
        assert_equal 500, limit

        (limit + 1).times { |i| backlog.add(user_id: i, stamp_key: "user_#{i}_invalidation", keys: ["user_#{i}"]) }

        assert_not backlog.include?('user_0_invalidation'), 'the oldest entry is dropped'
        assert backlog.include?("user_#{limit}_invalidation")
      end

      # ---- WS4 rolling deploy: a 0.13 process cannot reach this version's entries ----

      # During the 0.13 → 0.14 rolling deploy a 0.13 pod revokes a user's
      # last assignment: its invalidation removes the bare keys only, and
      # this version's namespaced entry keeps granting. The documented deploy
      # step, `rake permission_forge:cache:clear`, must leave that user no
      # granting entry at all (WS4 review K1 / N2).
      test 'INT-WS4 a user whose last assignment a 0.13 pod removed keeps no granting entry after rake permission_forge:cache:clear' do
        user = create_user
        set = readable_customer_set
        assignment = create_permission_set_user(user: user, permission_set: set)
        assert User.find(user.id).can_read?(:Customer)
        PermissionForge::PermissionSetUser.where(id: assignment.id).delete_all # the 0.13 pod: no callback of this version runs
        bare_keys = ["user_#{user.id}", "tenant_#{PermissionForge.ambient_tenant_id}_user_#{user.id}"]
        PermissionForge::Cache::Invalidation.call(user_id: user.id, stamp_key: "user_#{user.id}_invalidation", keys: bare_keys)
        assert User.find(user.id).can_read?(:Customer), 'why the deploy step exists: the 0.13 invalidation misses this version\'s entry'

        with_env('ACTOR' => 'ops: deploy', 'REASON' => 'deploy 0.14') { run_cache_clear_task }

        key = User.find(user.id).permission_cache_key
        ([key] + bare_keys).each { |name| assert_nil PermissionForge.cache.read(name), "#{name} after the clear" }
        assert_not User.find(user.id).can_read?(:Customer)
        assert_empty PermissionForge.cache.read(key).dig(:permissions, :resources), 'what the next request rebuilt grants nothing'
        assert_audit_event('cache.cleared', actor_label: 'ops: deploy', source: 'rake', reason: 'deploy 0.14')
      end

      # ---- NIT: dry runs raised on an assignment whose set is gone ----------------

      test 'INT-NIT the erasure and stale-assignment dry runs never raise on an orphaned assignment' do
        user = create_user
        set = readable_customer_set
        create_permission_set_user(user: user, permission_set: set, created_at: 2.years.ago, updated_at: 2.years.ago)
        PermissionForge::PermissionSet.where(id: set.id).delete_all # test setup: an orphan, as a legacy database has

        assert_nothing_raised do
          PermissionForge::Services::DataSubjectErasure.call(user: user, dry_run: true)
          PermissionForge::Services::StaleAssignmentAuditor.call(threshold_days: 90)
        end
      end

      # ---- claims #3: on_erasure ran inside the caller's transaction ---------------

      test 'INT-CL3 on_erasure runs after the caller transaction commits, never after a rollback' do
        user = create_user
        create_permission_set_user(user: user, permission_set: readable_customer_set)
        depth_seen = :never
        callback = ->(_user) { depth_seen = ActiveRecord::Base.connection.open_transactions }

        ActiveRecord::Base.transaction(requires_new: true) do
          PermissionForge::Services::DataSubjectErasure.call(user: user, on_erasure: callback)
          assert_equal :never, depth_seen, 'not yet: the erasure could still roll back'
        end
        assert_equal ActiveRecord::Base.connection.open_transactions, depth_seen, 'ran once the erasure was committed'

        other = create_user
        create_permission_set_user(user: other, permission_set: readable_customer_set(name: 'Other'))
        ran = false
        ActiveRecord::Base.transaction(requires_new: true) do
          PermissionForge::Services::DataSubjectErasure.call(user: other, on_erasure: ->(_u) { ran = true })
          raise ActiveRecord::Rollback
        end
        assert_not ran, "the host's deletion must not run for an erasure that was rolled back"
        assert_equal 1, PermissionForge::PermissionSetUser.where(user_id: other.id).count
      end

      # The gem's cache rake file in a Rake application of its own, loaded
      # once per process.
      def self.rake_application
        @rake_application ||= begin
          previous = Rake.application
          application = Rake.application = Rake::Application.new
          Rake::Task.define_task(:environment)
          load PermissionForge::Engine.root.join('lib/tasks/permission_forge_cache.rake').to_s
          Rake.application = previous
          application
        end
      end

      private

      def run_cache_clear_task
        previous = Rake.application
        Rake.application = self.class.rake_application
        Rake::Task['permission_forge:cache:clear'].reenable
        capture_io { Rake::Task['permission_forge:cache:clear'].invoke }
      ensure
        Rake.application = previous
      end

      def with_env(values)
        saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
        values.each { |key, value| ENV[key] = value }
        yield
      ensure
        saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end

      # Runs the block once, right after the cleaner's first DELETE (the
      # admin's renewal lands between the cleaner's selection and its work).
      def after_first_delete(&block)
        quoted = PermissionForge::PermissionSetUser.connection.quote_table_name(PermissionForge::PermissionSetUser.table_name)
        delete = /\ADELETE FROM #{Regexp.escape(quoted)}/i
        fired = false
        subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
          next if fired || !payload[:sql].match?(delete)

          fired = true
          block.call
        end
        @subscriptions = [*@subscriptions, subscription]
      end

      teardown { Array(@subscriptions).each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) } }
    end
  end
end
