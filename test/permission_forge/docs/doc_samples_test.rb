# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'json'
require 'tempfile'

module PermissionForge
  module Docs
    # The documentation, executed. test/support/docs_app.rb generates a Rails
    # 8.1 app shaped like `bin/rails generate authentication` + a scaffold
    # Customer in a child process, installs PermissionForge from the README's
    # own install lines, runs every `run` and `file=` block of README.md and
    # docs/*.md in it (one console per document, `# => literal` comments
    # asserted), then drives the denial flows the docs describe as requests
    # (the Turbo sign-in of a person with no set, the public index with and
    # without resume_session, the sign-in page under the guard, Option B,
    # the generated initializer's Option A with its audit_actor_resolver, ...). A second child is a `rails new --api` host. SQLite only, like the
    # fresh install test. The documents need Rails 8; the API-only host runs
    # on every Rails the gem supports (7.1 included).
    class DocSamplesTest < ActiveSupport::TestCase
      SCRIPT = File.expand_path('../../support/docs_app.rb', __dir__)
      FORBIDDEN = { 'status' => 403, 'layout' => true, 'sign_out' => true, 'forbidden_h1' => true }.freeze

      setup do
        skip 'the docs app is SQLite-only (the fresh install test is too)' unless ActiveRecord::Base.connection.adapter_name.match?(/sqlite/i)
      end

      # The documents and their flows need Rails 8 (the authentication
      # generator's app, params.expect, rate_limit): on Rails 7 the API-only
      # host below is what runs (it uses none of them).
      test 'every run and file= block of the documentation executes in the docs app, and every literal # => claim holds' do
        skip 'the documents describe a Rails 8 app (bin/rails generate authentication, params.expect, rate_limit)' if Rails::VERSION::MAJOR < 8

        result = docs_app('default')
        failures = result.fetch('documents').flat_map do |file, document|
          document.fetch('blocks').flat_map { |block| block_failures(file, block) }
        end
        assert_empty failures, "#{failures.size} documentation sample(s) failed:\n  #{failures.join("\n  ")}"
        assert_operator result['documents'].sum { |_file, document| document['blocks'].size }, :>=, 40, 'far fewer blocks ran than the docs hold'
        assert_equal 'permission_forge_', result.dig('install', 'table_prefix')
        assert_scenarios(result.fetch('scenarios'))
      end

      test 'an API-only host: the JSON API works, the admin names the middlewares it needs' do
        result = docs_app('api_only')
        assert_equal true, result['api_only']
        assert_equal 200, result['api_list_with_key']
        assert_equal 401, result['api_list_without_key']
        assert_equal 201, result['api_create_with_key']
        # The symptom the docs describe: no flash (its request methods are never loaded), and no session to write to.
        without = result.fetch('admin_page_without_middlewares')
        assert_includes %w[NameError ActionDispatch::Request::Session::DisabledSessionError], without['error'], without.inspect
        assert_match(/flash|sessions disabled/, without['message'].to_s)
        assert_equal 200, result.dig('admin_page_with_middlewares', 'status'), result['admin_page_with_middlewares'].inspect
        assert_admin_form_posts(result)
        warning = result['boot_warning'].to_s
        %w[ActionDispatch::Cookies ActionDispatch::Session::CookieStore ActionDispatch::Flash].each do |middleware|
          assert_includes warning, middleware, 'the boot warning names the middlewares the admin needs'
        end
        assert_match(/api_only/, warning)
      end

      private

      # The admin's New Permission Set form, posted behind the three
      # middlewares with forgery protection on: the token from the page
      # creates the set (a redirect to it); without the token, nothing.
      def assert_admin_form_posts(result)
        post = result.fetch('admin_post_with_middlewares')
        assert_equal [302, true, true], post.values_at('status', 'created', 'token_in_form'), post.inspect
        assert_match(%r{\A/permissions/permission_sets/\d+\z}, post['location'])
        refused = result.fetch('admin_post_without_token')
        assert_equal [false, 'ActionController::InvalidAuthenticityToken'], refused.values_at('created', 'error'), refused.inspect
      end

      def block_failures(file, block)
        failures = Array(block['expectations']).reject { |claim| claim['passed'] }
                                               .map { |claim| "#{file}:#{claim['line']}: # => #{claim['claim']} but got #{claim['actual']}" }
        return failures unless block['error']

        ["#{block['location']} (#{block['marker']}): #{block['error']}#{" at #{block['at']}" if block['at']}"] + failures
      end

      # The denial flows, as the docs describe them (docs/row-level-rules.md
      # "Handling Denials", docs/controller-actions.md "Callback order",
      # docs/getting-started.md, docs/admin-ui.md "Rails 8 authentication").
      def assert_scenarios(scenarios)
        errors = scenarios.select { |_name, outcome| outcome['error'] }
        assert_empty errors, "scenario(s) raised: #{errors.inspect}"
        assert_denial_flows(scenarios)
        assert_data_flows(scenarios)
        assert_setup_flows(scenarios)
      end

      # The sign-in and public-index flows of the Handling Denials section.
      def assert_denial_flows(scenarios)
        assert_dave(scenarios.fetch('dave_signin'))
        assert_equal({ 'hops' => [[302, '/session/new'], [200, nil]], 'looped' => false, 'sign_in_form' => 200 }, scenarios.fetch('signed_out_root'))
        assert_turbo_reload(scenarios.fetch('reload_after_turbo_signin'))
        assert_public_index(scenarios)
        assert_sign_in_page(scenarios.fetch('sign_in_page_guarded'))
      end

      # The wired scaffold: rows, masks, the JSON partial, the write path.
      def assert_data_flows(scenarios)
        assert_bob(scenarios.fetch('bob_opens_carols_customer'), scenarios.fetch('bob_api_customers'))
        assert_customers_json(scenarios.fetch('customers_json'))
        edit = scenarios.fetch('bob_edits_status')
        assert_equal [303, 'Acme Ltd', 'active', 'acme@example.test'], [edit.dig('status', 0), *edit.values_at('name', 'status_column', 'email')],
                     'PermitsAttributes keeps the editable field only'
        assert_equal({ 'rows' => ['Umbrella'], 'can_read' => false, 'index_status' => 403 }, scenarios.fetch('permission_scoped_without_read'))
      end

      # Option B, README step 4 after an admin-made set, seeds under :strict.
      def assert_setup_flows(scenarios)
        assert_equal({ 'signed_out' => [302, '/session/new'], 'bob' => [302, '/'], 'alice' => 200 }, scenarios.fetch('option_b_admin'))
        assert_name_taken(scenarios.fetch('name_taken'))
        assert_equal({ 'bare' => 2, 'wrapped' => 1, 'nil_user_strategy' => 'deny' }, scenarios.fetch('seeds_under_strict'))
        assert_option_a_audit_actor(scenarios.fetch('option_a_audit_actor'))
      end

      # The generated initializer's Option A with its commented
      # audit_actor_resolver uncommented: the person signed in to the app is
      # the actor of the admin view; without the resolver, or signed out, the
      # Basic auth login is.
      def assert_option_a_audit_actor(option_a)
        signed_in = option_a.fetch('signed_in')
        assert_equal [200, 'user', option_a['alice']], signed_in.values_at('status', 'actor_type', 'actor_id'), signed_in.inspect
        %w[without_resolver signed_out].each do |key|
          outcome = option_a.fetch(key)
          assert_equal [200, 'basic_auth', nil], outcome.values_at('status', 'actor_type', 'actor_id'), "#{key}: #{outcome.inspect}"
        end
      end

      # Signed in with no set: sent to the root, refused in the layout with a
      # way to sign out; Sign out lands on the form.
      def assert_dave(dave)
        assert_equal [302, '/'], dave['sign_in']
        assert_equal FORBIDDEN, dave['root']
        assert_equal [303, '/session/new'], dave['sign_out']
        assert_equal [200, true], dave.values_at('form_status', 'form_shown')
      end

      # Reload on /session/new while signed in: on to the root, refused there, once.
      def assert_turbo_reload(reload)
        assert_equal [[302, '/'], [403, nil]], reload['hops']
        assert_equal FORBIDDEN, reload.slice(*FORBIDDEN.keys)
      end

      # A guarded public index (allow_unauthenticated_access): without
      # resume_session a signed-in visitor is refused once — never a loop —
      # and with it gets the page, masked.
      def assert_public_index(scenarios)
        without = scenarios.fetch('public_index_without_resume_session')
        assert_equal false, without['looped'], "the public index loops without resume_session: #{without['hops'].inspect}"
        assert_equal [[403, nil]], without['hops']
        assert_equal FORBIDDEN, without.slice(*FORBIDDEN.keys)
        with = scenarios.fetch('public_index_with_resume_session')
        assert_equal [[200, nil]], with['hops']
        assert_equal [true, ['Acme']], with.values_at('masked', 'rows'), 'Bob reads his own customer, email masked'
      end

      def assert_bob(html, api)
        assert_equal FORBIDDEN.merge('reason' => true, 'own' => 200), html
        assert_equal({ 'status' => 403, 'body' => { 'error' => { 'status' => 403, 'messages' => ['Only your own customers'] } } }, api['denied'])
        assert_equal({ 'status' => 200, 'name' => 'Acme', 'masked' => true }, api['own'])
      end

      def assert_customers_json(json)
        assert_equal [200, ['Acme'], true], json.values_at('status', 'names', 'email_masked')
        assert_nil json['notes'], 'a column with no row is kept as null (unconfigured_field_strategy :block)'
        assert_includes json['keys'], 'notes'
      end

      def assert_sign_in_page(page)
        assert_equal FORBIDDEN.merge('sign_out' => false), page['without_exclusion'], 'the guard reaches the sign-in page'
        assert_equal 200, page['with_exclusion']
        assert_includes page['excluded'], 'sessions'
      end

      def assert_name_taken(taken)
        assert_equal 1, taken['taken'].size
        assert_match(/already used by another Permission Set|already been taken/, taken['taken'].first)
        assert_empty taken['retried']
        assert_operator taken['claims'].size, :>=, 2
        assert taken['claims'].all?, 'README step 5 holds once step 4 ran'
        assert_step_five_needs_step_four(taken['claims'], taken.fetch('without_assignment'))
      end

      # The documents run where nobody holds a set: without step 4's
      # assignment, step 5's claims fail (a fixture set would make them pass).
      def assert_step_five_needs_step_four(claims, without)
        assert_equal claims.size, without.size
        assert_not without.all?, "README step 5's claims must fail when step 4 assigns nothing: #{without.inspect}"
      end

      def docs_app(mode)
        Tempfile.create(['pf_docs_app', '.json']) do |file|
          output, status = Open3.capture2e({ 'RAILS_ENV' => 'test' }, RbConfig.ruby, SCRIPT, mode, file.path)
          result = File.size?(file.path) ? JSON.parse(File.read(file.path)) : {}
          assert status.success?, child_failure(mode, result, output)
          result
        end
      end

      def child_failure(mode, result, output)
        "docs app (#{mode}) failed: #{result['error']}\n#{Array(result['backtrace']).join("\n")}\n--- child output ---\n#{output.lines.last(25).join}"
      end
    end
  end
end
