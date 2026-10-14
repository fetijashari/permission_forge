# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'json'
require 'tempfile'

module PermissionForge
  module ReleaseReadiness
    # The pre-release review's findings that only show on a host running the shipped
    # defaults, which the suite never does (it runs on an empty prefix, a
    # memory cache, tenancy on, a Current class and users with a uuid). One
    # generated app in a child process, several checks — see
    # test/support/shipped_defaults_app.rb. Every check here failed on
    # v0.13.0.
    class ShippedDefaultsRegressionTest < ActiveSupport::TestCase
      SCRIPT = File.expand_path('../../support/shipped_defaults_app.rb', __dir__)

      # The child runs once per test process; every test reads its report.
      def self.result
        @result ||= Tempfile.create(['pf_shipped_defaults', '.json']) do |file|
          output, status = Open3.capture2e({ 'RAILS_ENV' => 'test' }, RbConfig.ruby, SCRIPT, file.path)
          result = File.size?(file.path) ? JSON.parse(File.read(file.path)) : {}
          result.merge('child_exit' => status.exitstatus, 'child_output' => output.lines.last(25).join)
        end
      end

      def result = self.class.result

      setup do
        assert_equal 0, result['child_exit'],
                     "the shipped-defaults app failed: #{result['error']}\n#{Array(result['backtrace']).join("\n")}\n#{result['child_output']}"
      end

      test 'the app runs on the shipped defaults' do
        assert_equal 'permission_forge_', result['table_prefix']
        assert_equal true, result['audit_trail_enabled']
        assert_equal false, result['users_have_uuid_column']
        assert_equal false, result['no_current_defined']
      end

      # integrity B1 / performance MAJOR-3
      test 'SHIP-B1 the app boots and eager-loads when the database cannot be reached' do
        assert_equal true, result['boot_without_database'], result['boot_without_database_error']
        assert_equal 'postgresql', result['boot_without_database_adapter']
        assert_equal 1, result['boot_without_database_skipped_logged'], 'one log line says the database checks were skipped'
      end

      # packaging M1 / claims #32
      test 'SHIP-M1 an app without a Current class is not signed in and still reads a masked model' do
        assert_nil result['no_current_error']
        assert_equal 'nil', result['no_current_resolver_answers']
        assert_equal true, result['no_current_masked_model_applied']
        assert_equal %w[walk-in walk-in@example.test], result['no_current_save_find_read']
      end

      # integrity B2 / WS3-B1
      test 'SHIP-B2 a set assigned by a signed-in admin builds the holder permissions without a uuid column' do
        assert_nil result['granted_by_admin_error']
        assert_equal true, result['granted_by_admin_stamped']
        assert_equal true, result['granted_by_admin_can_read']
        assert_equal true, result['granted_by_admin_email_masked']
        assert_kind_of Integer, result['granted_by_admin_grantor'], 'the grantor is named by id'
      end

      # claims #1 / WS5-B1
      test 'SHIP-CSRF a forged POST with the admin session cookie is refused by a session-based api_auth' do
        assert_nil result['csrf_error']
        assert_equal 200, result['csrf_admin_session_established']
        assert_equal 403, result['csrf_forged_post_status']
        assert_equal false, result['csrf_forged_post_created']
        assert_equal 201, result['csrf_post_with_token_status']
        assert_equal true, result['csrf_post_with_token_created']
      end

      # web MAJOR-3 / WS5-M2
      test 'SHIP-M3 api_require_authorization defaults to true: identity alone changes nothing' do
        assert_nil result['identity_only_error']
        assert_equal true, result['generated_api_require_authorization']
        assert_equal 200, result['identity_only_read_status']
        assert_equal [403, 403, 403], result.values_at('identity_only_create_status', 'identity_only_widen_status', 'identity_only_assign_status')
        assert_equal false, result['identity_only_changed_anything']
      end

      # core-security fail-open note / WS5-M3, WS5-B3, WS1-M2
      # Q5: ActiveRecord::Base loads after config/initializers (the models are
      # autoloaded), so Rails' copy of config.filter_parameters into
      # ActiveRecord::Base.filter_attributes sees the host's entries and the
      # gem's GDPR patterns — which match whole name segments, not substrings.
      test 'SHIP-Q5 config.filter_parameters reaches ActiveRecord::Base.filter_attributes, GDPR patterns included' do
        assert_equal true, result['filter_attributes_from_host'], 'a filter_parameter_logging entry filters #inspect'
        assert_equal %w[email name phone_number telephone zipcode], result['inspect_filtered_names'].sort
        assert_match(/name: \[FILTERED\], email: \[FILTERED\]/, result['customer_inspect'])
      end

      test 'SHIP-DEFAULTS the generated initializer closes the fail-open defaults for new installs' do
        assert_equal 'deny', result['generated_action_guard_nil_user_strategy']
        # Q8: the safe subset, written explicitly; config.preset = :strict is offered commented.
        assert_equal true, result['generated_conditional_sets_strict_mode']
        assert_equal 'compat', result['generated_preset']
        assert_equal 'deny', result['generated_admin_tenantless_access']
        assert_equal false, result['generated_nested_attributes_parent_fallback']
      end
    end
  end
end
