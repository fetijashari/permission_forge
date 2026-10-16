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
      # Every file of the admin's controllers that can answer: the
      # controllers, the modules they share (permission_set_editor.rb) and
      # the admin's concerns (the API's live under api/).
      CONTROLLERS = %w[app/controllers/permission_forge/*.rb app/controllers/concerns/permission_forge/*.rb].freeze
      # A 422 however it is written (Rack renamed the symbol in 3.1).
      UNPROCESSABLE = /\bunprocessable_(?:entity|content)\b|(?<![\w.])422(?![\w.])/
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

      test 'every template under app/views is rendered by a walked screen' do
        missing = all_templates - NOT_WALKED.keys - rendered_templates { walk_every_screen }

        assert_empty missing, 'templates no walked screen renders (add the screen or its fixture to AdminPaths / ' \
                              "AdminPagePaths, or say why in NOT_WALKED): #{missing.join(', ')}"
        assert_empty NOT_WALKED.keys - all_templates, 'NOT_WALKED names a template that is gone: remove it'
      end

      test 'every POST answered with a page renders it' do
        posted_pages.each do |page|
          post pf(page.path), params: page.params
          assert_response :success, "POST #{page.path}"
          assert_empty body_problems(response.body), "POST #{page.path}"
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
        assert_equal %w[editor#a editor#b editor#c],
                     sites_in('editor', ["def a\n", "render :x, status: :unprocessable_content\n", "def b\n", "head 422\n",
                                         "def c\n", "render :x, status: :unprocessable_entity\n", "def d\n", "# 422 in a comment\n",
                                         "x = 4220\n"])

        home_only = rendered_templates { get pf('/') }
        assert_includes all_templates - home_only, 'permission_sets/review.html.erb', 'a screen not walked leaves its template'
        assert_includes home_only, 'home/_secret_rules_card.html.erb', 'a card is rendered through its partial'
      end

      # Templates (relative to app/views/permission_forge, layouts by their
      # path under app/views) the walk does not render, and why. None today:
      # every template is on a walked screen.
      NOT_WALKED = {}.freeze
      VIEWS_ROOT = File.join(ROOT_DIR, 'app/views').freeze
      RENDER_EVENTS = /\Arender_(template|partial|collection|layout)\.action_view\z/

      private

      def all_templates
        Dir[File.join(VIEWS_ROOT, '**/*.erb')].map { |file| template_name(file) }.sort
      end

      def template_name(file)
        file.delete_prefix("#{VIEWS_ROOT}/").delete_prefix('permission_forge/')
      end

      # The templates rendered while the block runs (ActionView's own events).
      def rendered_templates(&)
        rendered = Set.new
        callback = lambda do |*, payload|
          [payload[:identifier], payload[:layout]].compact.each do |file|
            rendered << template_name(file.to_s) if file.to_s.start_with?(VIEWS_ROOT)
          end
        end
        ActiveSupport::Notifications.subscribed(callback, RENDER_EVENTS, &)
        rendered.to_a
      end

      # Every screen of the whole-UI walks: the pages, a drawer as the script
      # loads it, the error states, the flows' toasts, the posted pages and
      # the screens a setting draws.
      def walk_every_screen # rubocop:disable Metrics/AbcSize -- one line per kind of screen
        paths.each { |path| get pf(path) }
        get pf("/people/#{@ana.id}/remove_all"), headers: { 'X-PF-Fragment' => '1' }
        error_states.select(&:renders?).each { |state| send(state.verb, pf(state.path), params: state.params) }
        flows.each do |flow|
          send(flow.verb, pf(flow.path), params: flow.params)
          follow_redirect!
        end
        extra_screens
      end

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

      # "permission_sets#create" for every line of an admin controller (or a
      # module or concern it includes) that answers 422, named by the method
      # that contains it. Comments and strings do not count (StaticGuard.code_of).
      def unprocessable_sites(files = CONTROLLERS.flat_map { |glob| Dir[File.join(ROOT_DIR, glob)] })
        files.flat_map { |file| sites_in(File.basename(file, '.rb').delete_suffix('_controller'), File.readlines(file)) }.uniq.sort
      end

      def sites_in(owner, lines)
        method = nil
        lines.filter_map do |line|
          method = Regexp.last_match(1) if line =~ /^\s*def\s+([a-z_]+[!?]?)/
          "#{owner}##{method}" if StaticGuard.code_of(line).match?(UNPROCESSABLE)
        end
      end

      def problems_of(state, locale)
        send(state.verb, pf(state.path), params: state.params.merge(locale: locale))
        problems = response.status == 422 ? rendered_problems(state) : ["answered #{response.status}, want 422"]
        problems.map { |problem| "#{locale} #{state.verb.upcase} #{state.path}: #{problem}" }
      end

      def rendered_problems(state)
        state.renders? ? body_problems(response.body) : []
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
