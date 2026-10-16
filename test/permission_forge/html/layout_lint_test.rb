require_relative 'admin_test_case'
require_relative 'admin_page_paths'
require_relative 'layout_lint'
require 'support/static_guard'

module PermissionForge
  module Html
    # Layout holds at phone width (plan class LY), without a browser: every
    # placeholder fits its box in every locale, every wide grid is rendered in
    # a scroll frame that is reachable and named, every scroll container is
    # the containing block of what it clips, and nothing forbids wrapping
    # around host text. The browser probe (test/browser/layout_probe.js,
    # `browser` CI job) measures the real widths.
    class LayoutLintTest < AdminTestCase
      include AdminPagePaths

      ROOT_DIR = File.expand_path('../../..', __dir__)
      CSS_PATH = 'app/frontend/permission_forge/pf_admin.css'.freeze
      VIEWS = 'app/views/permission_forge/**/*.erb'.freeze
      PLACEHOLDER_CALL = /placeholder="<%= t\('([^']+)'/
      # Every placeholder attribute a view writes, whatever its form.
      PLACEHOLDER_ATTR = /placeholder="([^"]*)"/
      CONTROL = /<(input|textarea)\b/
      # Placeholders that show host data (not a translation, not a literal):
      # the view, and why. Their rendered value is checked on every walked
      # screen (review R4 P2-6).
      HOST_PLACEHOLDERS = {
        'app/views/permission_forge/resource_fields/show.html.erb' =>
          "the field's label or its name: the Label input shows what the drawer calls the field when it is empty"
      }.freeze

      test 'every placeholder fits a phone-width box in every locale' do
        problems = placeholders.flat_map do |view, kind, key|
          PermissionForge::BUNDLED_LOCALES.filter_map do |locale|
            text = I18n.t(key, locale: locale, default: nil)
            next "#{view}: #{key} is missing in #{locale}" unless text.is_a?(String)

            problem = LayoutLint.placeholder_problem(kind, text, locale: locale)
            "#{view}: #{key}: #{problem}" if problem
          end
        end

        assert_operator placeholders.size, :>=, 10, 'the view scan found almost no placeholders: check PLACEHOLDER_CALL'
        assert_empty problems, problems.join("\n")
      end

      test 'every wide grid is in a scroll frame that is reachable and named, on every screen' do
        assert_operator lint.wide_classes.size, :>=, 4, "wide classes: #{lint.wide_classes.inspect}"
        problems = screens.flat_map { |label, body| lint.page_problems(body).map { |problem| "#{label}: #{problem}" } }

        assert_empty problems, problems.join("\n")
      end

      test 'every scroll container in the stylesheet is a containing block, and the frame paints its cue' do
        assert_empty lint.css_problems, lint.css_problems.join("\n")
      end

      # A literal is checked as written; a placeholder that is neither a
      # translation nor a literal is host data and must be listed.
      test 'every placeholder is a translation, a literal that fits, or listed host data' do
        problems = placeholder_forms.flat_map do |view, kind, value|
          case value
          when /\A<%= t\('/ then [] # the per-locale test above
          when /<%/ then HOST_PLACEHOLDERS.key?(view) ? [] : ["#{view}: placeholder #{value.inspect} is host data: list it in HOST_PLACEHOLDERS"]
          else [LayoutLint.placeholder_problem(kind, value, locale: 'en')].compact.map { |problem| "#{view}: #{problem}" }
          end
        end

        assert_operator placeholder_forms.count { |_, _, value| !value.include?('<%') }, :>=, 3, 'the literal placeholders were not found'
        assert_empty problems, problems.join("\n")
        assert_empty HOST_PLACEHOLDERS.keys - placeholder_forms.select { |_, _, value| value.match?(/<%=(?! t\()/) }.map(&:first),
                     'HOST_PLACEHOLDERS names a view without such a placeholder: remove it'
      end

      test 'every placeholder a walked screen renders fits its box' do
        problems = screens.flat_map do |label, body|
          Nokogiri::HTML5(body).css('input[placeholder], textarea[placeholder]').filter_map do |control|
            kind = control.name == 'textarea' ? :textarea : :input
            problem = LayoutLint.placeholder_problem(kind, control['placeholder'], locale: 'en')
            "#{label}: #{problem}" if problem
          end
        end

        assert_empty problems.uniq, problems.uniq.join("\n")
      end

      test 'pf-nowrap never wraps interpolated text' do
        hits = StaticGuard.scan(globs: VIEWS, needle: /pf-nowrap.*<%=|<%=.*pf-nowrap/, strings: :keep)

        assert_empty hits.map(&:to_s), 'host text (a name, an email) in a pf-nowrap element cannot wrap at phone width'
      end

      # Negative fixtures: what each lint is for.
      test 'the lint itself catches what it is for' do
        assert_match(/41 characters \(latin limit 40\)/, LayoutLint.placeholder_problem(:input, 'x' * 41, locale: 'en'))
        assert_match(/35 characters \(cyrillic limit 34\)/, LayoutLint.placeholder_problem(:input, 'ж' * 35, locale: 'mk'))
        assert_match(/61 characters/, LayoutLint.placeholder_problem(:textarea, "short\n#{'y' * 61}", locale: 'en'))
        assert_nil LayoutLint.placeholder_problem(:input, 'x' * 40, locale: 'en')
        assert_nil LayoutLint.placeholder_problem(:textarea, "#{'y' * 60}\n#{'z' * 60}", locale: 'en')

        bad_css = ".pf-table--sets { min-width: 560px; }\n.pf-scroll-x { overflow-x: auto; }\n.pf-pane { overflow-y: scroll; }\n" \
                  "@supports (x: y) {\n  .pf-box { position: relative; overflow: auto; }\n}\n" \
                  ".pf-toasts { position: fixed; left: 50%; }"
        bad = LayoutLint.new(css: bad_css)
        assert_equal ['pf-table--sets'], bad.wide_classes
        assert_equal ['.pf-scroll-x scrolls but is no containing block: add position: relative',
                      '.pf-pane scrolls but is no containing block: add position: relative',
                      '.pf-scroll-x paints no scroll cue (the edge gradients)',
                      '.pf-toasts is centred on the viewport: move it by the sidebar (var(--pf-sidebar-width)) at desktop widths'],
                     bad.css_problems
        offset = "@media (min-width: 1024px) { .pf-root:has(.pf-sidebar) .pf-toasts { left: calc(50% + var(--pf-sidebar-width) / 2); } }"
        assert_equal ['no .pf-scroll-x rule'], LayoutLint.new(css: ".pf-toasts { position: fixed; left: 50%; }\n#{offset}").css_problems

        html = '<div class="pf-card"><div class="pf-table pf-table--sets"></div></div>' \
               '<div class="pf-scroll-x"><div class="pf-table pf-table--sets"></div></div>' \
               '<section class="pf-scroll-x" tabindex="0" aria-labelledby="h"><h2 id="h">x</h2></section>' \
               '<div class="pf-scroll-x" role="region" tabindex="0" aria-label="Sets"></div>'
        assert_equal ['<div class=pf-table pf-table--sets> is 480px or wider with no .pf-scroll-x ancestor (pf_scroll_frame)',
                      '<div class=pf-scroll-x> has no tabindex=0', '<div class=pf-scroll-x> has no aria-label or aria-labelledby',
                      '<div class=pf-scroll-x> is no region'], bad.page_problems(html)
      end

      private

      def lint
        @lint ||= LayoutLint.new(css: File.read(File.join(ROOT_DIR, CSS_PATH)))
      end

      # [view, :input | :textarea, full key] for every placeholder a view
      # takes from the locale files.
      def placeholders
        @placeholders ||= Dir[File.join(ROOT_DIR, VIEWS)].flat_map do |file|
          view = file.delete_prefix("#{ROOT_DIR}/")
          source = File.read(file)
          source.to_enum(:scan, PLACEHOLDER_CALL).map do
            match = Regexp.last_match
            kind = source[0...match.begin(0)][/.*#{CONTROL}/m, 1]
            [view, kind.to_sym, full_key(view, match[1])]
          end
        end
      end

      # [view, :input | :textarea, raw attribute value] for every placeholder of every view.
      def placeholder_forms
        @placeholder_forms ||= Dir[File.join(ROOT_DIR, VIEWS)].flat_map do |file|
          view = file.delete_prefix("#{ROOT_DIR}/")
          source = File.read(file)
          source.to_enum(:scan, PLACEHOLDER_ATTR).map do
            match = Regexp.last_match
            [view, source[0...match.begin(0)][/.*#{CONTROL}/m, 1].to_sym, match[1]]
          end
        end
      end

      def full_key(view, key)
        return key unless key.start_with?('.')

        scope = view.delete_prefix('app/views/permission_forge/').delete_suffix('.html.erb')
                    .split('/').map { |part| part.delete_prefix('_') }.join('.')
        "permission_forge.#{scope}#{key}"
      end

      # Every page, every rendered error state and every extra screen, once
      # (the markup does not change with the locale).
      def screens
        page_screens + error_screens + extra_screens
      end

      def page_screens
        paths.map do |path|
          get pf(path)
          ["GET #{path}", response.body]
        end
      end
    end
  end
end
