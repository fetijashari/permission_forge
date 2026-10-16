# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/rake_tasks'

module PermissionForge
  # DRY_RUN= as the deleting rake tasks read it (RakeDryRun): only an
  # explicit false runs for real. The erasure treated only the literal
  # `true` as a dry run, so `DRY_RUN=1` (the value the purge documented for
  # a dry run) erased the person. Unset, each task keeps its default: the
  # erasure is a dry run, the purge deletes.
  class GdprErasureTaskTest < ActiveSupport::TestCase
    include RakeTasks::Case

    setup do
      @user = create_user(name: 'Dry Run Dana')
      @assignment = create_permission_set_user(user: @user, permission_set: create_permission_set(name: 'Dry Run Set'))
    end

    def erase(dry_run)
      ENV.update('USER_ID' => @user.id.to_s, 'ACTOR' => 'dpo')
      dry_run.nil? ? ENV.delete('DRY_RUN') : ENV['DRY_RUN'] = dry_run
      run_task('permission_forge:erasure')
    end

    def assigned? = PermissionForge::PermissionSetUser.exists?(@assignment.id)

    test 'DRY_RUN values other than an explicit false are a dry run' do
      [nil, '', 'true', 'TRUE', '1', 'yes', 'Yes', 'y', 'ture', ' 1 '].each do |value|
        out, = erase(value)

        assert_includes out, 'Dry run', "DRY_RUN=#{value.inspect} is a dry run"
        assert assigned?, "DRY_RUN=#{value.inspect} erased nothing"
      end
      assert_no_audit_event_for_erasure
    end

    test 'an explicit false, 0 or no erases, in any case' do
      %w[false FALSE 0 no No].each_with_index do |value, index|
        @assignment = create_permission_set_user(user: @user, permission_set: create_permission_set(name: "Set #{index}"))
        out, = erase(value)

        assert_includes out, 'Erasure complete', "DRY_RUN=#{value.inspect} executes"
        assert_not assigned?, "DRY_RUN=#{value.inspect} removed the assignment"
      end
    end

    test 'the purge deletes when DRY_RUN is unset or false, and only counts for any other value' do
      PermissionForge.configuration.audit_retention_period = 30.days
      { '1' => true, 'yes' => true, 'TRUE' => true, 'on' => true, nil => false, '' => false, 'no' => false, '0' => false }.each do |value, counts|
        old = PermissionForge::Audit.record('report.generated', occurred_at: 90.days.ago, data: {})
        value.nil? ? ENV.delete('DRY_RUN') : ENV['DRY_RUN'] = value
        out, = run_task('permission_forge:audit_events:purge')

        assert_equal counts, out.include?('Dry run'), "DRY_RUN=#{value.inspect}: #{out}"
        assert_equal counts, PermissionForge::AuditEvent.unscoped.exists?(old.id), "DRY_RUN=#{value.inspect}"
      end
    end

    test 'the parser: unset keeps the default, an explicit false executes, anything else is a dry run' do
      assert RakeDryRun.dry_run?(nil, default: true)
      assert_not RakeDryRun.dry_run?(nil, default: false)
      assert_not RakeDryRun.dry_run?('  ', default: false)
      assert RakeDryRun.dry_run?('maybe', default: false)
      assert_not RakeDryRun.dry_run?(' No ', default: true)
    end

    private

    def assert_no_audit_event_for_erasure
      assert_not PermissionForge::AuditEvent.unscoped.where(event: 'erasure.performed', record_id: @user.id.to_s).exists?,
                 'a dry run writes no erasure.performed event'
    end
  end
end
