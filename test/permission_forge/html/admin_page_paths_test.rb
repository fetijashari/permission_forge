require_relative 'admin_test_case'
require_relative 'admin_page_paths'
require_relative 'a11y_lint'
require 'support/static_guard'

module PermissionForge
  module Html
    # The screen list is complete: every GET route of the admin is reached by a
    # path of AdminPaths, and every answer the admin renders with 422 has an
    # error state that reaches it, so a new page or a new refused form is
    # walked by every whole-UI test the day it is added. The error states
    # themselves are answered with 422 and render clean in every locale.
    class AdminPagePathsTest < AdminTestCase
      include AdminPagePaths

      ROOT_DIR = File.expand_path('../../..', __dir__)
      CONTROLLERS = 'app/controllers/permission_forge/*_controller.rb'.freeze
      # GET routes that answer no page.
      NOT_PAGES = {
        'assets#show' => 'the engine-served stylesheet, script and brand files (assets_test.rb)',
        'audit_events#holdings' => 'a CSV export (audit_export_streaming_test.rb)'
      }.freeze

      test 'every GET route of the admin is reached by a screen' do
        routes = admin_get_routes
        missing = routes - NOT_PAGES.keys - paths.map { |path| recognized(path) }

        assert_empty missing, "GET routes no path of AdminPaths reaches (add the page, with its fixture): #{missing.join(', ')}"
        assert_empty NOT_PAGES.keys - routes, 'NOT_PAGES names a route that is gone: remove it'
      end

      test 'every 422 render site of the admin has an error state that reaches it' do
        sites = unprocessable_sites
        listed = error_states.map(&:site).uniq

        assert_empty sites - listed, "422 render sites with no error state in AdminPaths#error_states: #{(sites - listed).join(', ')}"
        assert_empty listed - sites, "error states for render sites that are gone: #{(listed - sites).join(', ')}"
      end

      test 'every error state is answered with 422, translated, CSP-safe and accessible, in every locale' do
        failures = PermissionForge::BUNDLED_LOCALES.flat_map do |locale|
          error_states.flat_map { |state| problems_of(state, locale) }
        end

        assert_empty failures, failures.join("\n")
      end

      test 'a change redirects to a page with a toast' do
        flows.each do |flow|
          send(flow.verb, pf(flow.path), params: flow.params)

          assert_response :redirect, "#{flow.verb} #{flow.path}"
          follow_redirect!
          assert_response :success
          assert_select '.pf-toast', minimum: 1
        end
      end

      # Negative fixtures: a page dropped from the list leaves its route
      # unreached; an error state dropped leaves its render site uncovered.
      test 'the meta tests bite' do
        without_settings = paths.reject { |path| path.start_with?('/settings') }.map { |path| recognized(path) }
        assert_includes admin_get_routes - without_settings, 'settings#show'

        without_resources = error_states.reject { |state| state.site == 'resources#create' }.map(&:site)
        assert_includes unprocessable_sites - without_resources, 'resources#create'
        assert_includes unprocessable_sites, 'permission_set_rules#save_rule', 'a site is named by its enclosing def'
      end

      private

      # "people#show" for every GET route the engine draws for the admin (the
      # JSON API has its own enumeration, security/route_fuzz_test.rb).
      def admin_get_routes
        PermissionForge::Engine.routes.routes.filter_map do |route|
          controller = route.requirements[:controller].to_s
          next unless route.verb.to_s.include?('GET') && controller.start_with?('permission_forge/')
          next if controller.start_with?('permission_forge/api/')

          "#{controller.delete_prefix('permission_forge/')}##{route.requirements[:action]}"
        end.uniq
      end

      def recognized(path)
        route = PermissionForge::Engine.routes.recognize_path(path.split('?').first, method: :get)
        "#{route[:controller].delete_prefix('permission_forge/')}##{route[:action]}"
      end

      # "permission_sets#create" for every line of an admin controller that
      # answers :unprocessable_entity, named by the method that contains it.
      # Comments and strings do not count (StaticGuard.code_of).
      def unprocessable_sites
        Dir[File.join(ROOT_DIR, CONTROLLERS)].flat_map do |file|
          controller = File.basename(file, '_controller.rb')
          method = nil
          File.readlines(file).filter_map do |line|
            method = Regexp.last_match(1) if line =~ /^\s*def\s+([a-z_]+[!?]?)/
            "#{controller}##{method}" if StaticGuard.code_of(line).include?('unprocessable_entity')
          end
        end.uniq.sort
      end

      def problems_of(state, locale)
        send(state.verb, pf(state.path), params: state.params.merge(locale: locale))
        label = "#{locale} #{state.verb.upcase} #{state.path}"
        return ["#{label}: answered #{response.status}, want 422"] unless response.status == 422
        return [] unless state.renders?

        body_problems(response.body).map { |problem| "#{label}: #{problem}" }
      end

      def body_problems(body)
        problems = []
        problems << 'missing translation' if body.match?(/translation[ _]missing/i)
        problems << 'inline style' if body.match?(/\sstyle="/)
        problems << 'inline script' if body.match?(/<script(?![^>]*\ssrc=)/)
        problems << 'inline handler' if body.match?(/\son[a-z]+="/)
        problems + A11yLint.new(body).problems
      end
    end
  end
end
