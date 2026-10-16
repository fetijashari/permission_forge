# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/rake_tasks'

module PermissionForge
  module Tasks
    # Field test round 7 (E#55): a dry run said what a real run does — the
    # purge's dry run printed "Would delete 3 audit event(s)" and then the
    # key line "Audit events deleted: 3" — and the consent withdrawal's dry
    # run answered `cache: { confirmed: true }` for cache work it never did.
    # RakeOutput's labels follow `dry_run` (one table: a key whose label
    # says a change was made has a "would" form), and every dry run's cache
    # outcome is "no cache work" (Cache::Outcome.none: `confirmed` nil,
    # `work` false), which the rake line and the service's answer say.
    class DryRunOutputTest < ActiveSupport::TestCase
      include RakeTasks::Case

      DONE = /\b(?:deleted|removed|cleared|invalidated|scrubbed)\b/i

      setup do
        @user = create_user(name: 'Dee Dry', email: 'dee@acme.test')
        @old_retention = PermissionForge.configuration.audit_retention_period
      end

      teardown do
        PermissionForge.configuration.audit_retention_period = @old_retention
      end

      test 'every label that says a change was made has its "would" form' do
        done = RakeOutput::LABELS.keys.select { |key| RakeOutput.label(key).match?(DONE) }
        assert_includes done, 'purged'

        done.each do |key|
          would = RakeOutput.label(key, dry_run: true)
          assert_match(/\bwould\b/i, would, key)
          assert_no_match DONE, would.sub(/would be \w+/i, ''), "#{key}: #{would}"
        end
        assert_equal RakeOutput.label('strategy'), RakeOutput.label('strategy', dry_run: true), 'a label of no change reads the same'
      end

      test 'negative fixture: a done label without a would form is caught' do
        assert_match DONE, 'Audit events deleted'
        assert_no_match(/\bwould\b/, 'Audit events deleted')
      end

      test 'the purge\'s dry run says would on every line' do
        PermissionForge.configuration.audit_retention_period = 30.days
        create_permission_set(name: 'Purge me')
        PermissionForge::AuditEvent.unscoped.update_all(occurred_at: 40.days.ago)
        ENV['DRY_RUN'] = '1'

        out, err, status = run_task('permission_forge:audit_events:purge')
        assert_nil status, err

        assert_includes out, "#{RakeOutput.label('purged', dry_run: true)}:"
        assert_includes out, "#{RakeOutput.label('cutoff', dry_run: true)}:"
        assert_not_includes out, "#{RakeOutput.label('purged')}:", out
        assert_not_includes out, "#{RakeOutput.label('cutoff')}:", out
      end

      test 'the consent withdrawal\'s dry run did no cache work, and says so' do
        set = create_permission_set(name: 'Newsletter', requires_session_flag: 'marketing_consent')
        create_permission_set_user(user: @user, permission_set: set)

        result = Services::ConsentWithdrawalHandler.call(user: @user, consent_flag: 'marketing_consent', dry_run: true)
        outcome = Cache::Outcome.wrap(result[:cache])

        assert_nil outcome.confirmed, 'nothing to confirm: nothing was asked of the store'
        assert_equal false, outcome.work
        assert_predicate outcome, :none?
        assert_includes RakeOutput.lines(result).join("\n"), RakeOutput::CONFIRMED.fetch(:none)
      end

      test 'every dry run answers no cache work' do
        set = create_permission_set(name: 'Ending')
        create_permission_set_user(user: @user, permission_set: set).update_columns(expires_at: 1.day.ago)

        { 'erasure' => Services::DataSubjectErasure.call(user: @user, dry_run: true),
          'expired' => Services::ExpiredAssignmentCleaner.call(dry_run: true) }.each do |name, result|
          assert_predicate Cache::Outcome.wrap(result.fetch(:cache)), :none?, name
        end

        ENV['USER_ID'] = @user.id.to_s
        out, = run_task('permission_forge:erasure')
        assert_includes out, RakeOutput::CONFIRMED.fetch(:none)
        assert_not_includes out, RakeOutput::CONFIRMED.fetch(nil), 'never "follows the commit" for a dry run'
      end

      test 'Outcome.none and Report#none: nothing confirmed, no work, the scope and origin as measured' do
        none = Cache::Report.new.none
        assert_equal [nil, false, 0], [none.confirmed, none.work, none.unconfirmed]
        assert_equal PermissionForge.cache.process_local?, none.process_local
        assert_equal none, Cache::Outcome.wrap(none.to_h), 'survives the service hash'
        assert_equal true, Cache::Report.of { nil }.work, 'a measured operation did its work'
        assert_not_predicate Cache::Report.of { nil }, :none?
      end
    end
  end
end
