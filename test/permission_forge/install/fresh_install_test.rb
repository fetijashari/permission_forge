require 'test_helper'
require 'open3'
require 'json'
require 'tempfile'

module PermissionForge
  module Install
    # The rest of the suite runs on a hand-written schema with an empty table
    # prefix, a memory cache and tenancy switched on. This test installs the
    # gem into a brand-new Rails app in a child process — the real generator
    # with default flags, the generated initializer and migration, the stock
    # `rails new` test settings — and checks that the core contract holds.
    # See test/support/fresh_install_app.rb.
    class FreshInstallTest < ActiveSupport::TestCase
      SCRIPT = File.expand_path('../../support/fresh_install_app.rb', __dir__)

      # What a fresh install must report, whatever the type of the user keys.
      CONTRACT = {
        'table_prefix' => 'permission_forge_',
        'preset' => 'compat', # :strict is offered commented
        'cache_store' => 'ActiveSupport::Cache::NullStore', # what `rails new` configures for tests
        'models_with_rows' => 8,
        'assignment_stores_the_full_user_id' => true,
        'audit_runs' => true,
        # the assigned user
        'ann_can_read' => true,
        'ann_can_delete' => false,
        'ann_can_export' => true,
        'ann_email_masked' => true,
        'ann_rule_count' => 1,
        # the row-level rule is enforced
        'find_by_own_row' => 'found',
        'find_by_other_row' => 'denied',
        'permission_scoped' => %w[mine],
        # a user who was never assigned, whose id looks like the assigned user's
        'lookalike_user_can_read' => false,
        'lookalike_user_sets' => [],
        # bulk assignment by id reaches the right user
        'bulk_assigned' => 1,
        'bulk_assigned_the_right_user' => ['Sales rep'],
        'set_users' => %w[Ann Cat],
        # the admin refuses access until credentials are set, then renders
        'admin_without_credentials' => 401,
        'admin_home' => 200,
        'admin_permission_sets' => 200,
        'admin_permission_set' => 200,
        'admin_person' => 200,
        'api_when_disabled' => 404,
        # nobody signed in: a masked model is saved, found and read
        'signed_out_error' => nil,
        'signed_out_current_user' => 'nil',
        'signed_out_masked_attributes' => true,
        'signed_out_saved' => %w[walk-in walk-in@example.test],
        'signed_out_save_find_read' => %w[walk-in walk-in@example.test],
        'signed_out_unscoped_read' => %w[walk-in walk-in@example.test],
        # ... but in a web request (a host page nobody signed in to) the
        # generated :hide_in_requests hides it
        'signed_out_request_read' => [nil, nil],
        # an assignment made by a signed-in admin is stamped with the admin
        'granted_by_admin_stamped' => true,
        # a model first named in this process is masked in another one at its
        # next request or job: [masked before, masked after]
        'other_process_masked' => [false, true],
        # :hide set, the user model with a Resource row: nobody signed in
        # (sign-in) reads it as stored; another masked model reads hidden
        'user_model_masked' => true,
        'user_model_signed_out_read' => %w[Ann ann@example.test],
        'other_model_signed_out_read' => [nil, nil]
      }.freeze

      test 'a default install on integer user keys works end to end' do
        result = fresh_install('default')

        assert_equal 'integer', result['user_id_column_type']
        assert_contract(result)
      end

      test 'a default install on string (UUID-style) user keys keeps users apart' do
        result = fresh_install('string_keys')

        assert_equal 'string', result['user_id_column_type'], 'user_id must have the type of the user primary key'
        assert_contract(result)
      end

      # The generated initializer must not assume ActiveSupport::CurrentAttributes:
      # with no Current class, nobody is signed in until the app wires its
      # resolver. This app's users have a uuid column, which the profile keeps.
      test 'a default install works in an app without Current' do
        result = fresh_install('no_current')

        assert_contract(result)
        assert_equal({ 'uuid' => 'uuid-of-ann', 'name' => 'Ann', 'email' => 'ann@example.test' }, result['ann_profile'])
      end

      private

      def fresh_install(scenario)
        Tempfile.create(['pf_fresh_install', '.json']) do |file|
          output, status = Open3.capture2e({ 'RAILS_ENV' => 'test' }, RbConfig.ruby, SCRIPT, scenario, file.path)
          result = File.size?(file.path) ? JSON.parse(File.read(file.path)) : {}
          assert status.success?, failure_message(scenario, result, output)
          result
        end
      end

      def failure_message(scenario, result, output)
        "fresh install (#{scenario}) failed: #{result['error']}\n#{Array(result['backtrace']).join("\n")}\n" \
          "--- child output ---\n#{output.lines.last(25).join}"
      end

      def assert_contract(result)
        CONTRACT.each do |key, expected|
          message = "fresh install (#{result['scenario']}): #{key}"
          expected.nil? ? assert_nil(result[key], message) : assert_equal(expected, result[key], message)
        end
        assert_equal({ 'uuid' => nil, 'name' => 'Ann', 'email' => 'ann@example.test' }, result['ann_profile']) unless
          result['scenario'] == 'no_current'
        assert_granted_by_admin(result)
      end

      # The users table has no uuid column (except in no_current): a set
      # assigned by a signed-in admin must still build the holder's hash.
      def assert_granted_by_admin(result)
        assert_equal true, result['granted_by_admin_can_read'], "fresh install (#{result['scenario']}): granted_by_admin_can_read"
      end
    end
  end
end
