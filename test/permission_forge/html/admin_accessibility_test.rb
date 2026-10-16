require_relative 'admin_test_case'
require_relative 'admin_page_paths'
require_relative 'a11y_lint'

module PermissionForge
  module Html
    # Every admin screen passes the structural accessibility lint (one h1,
    # landmarks, names for every control, labelled tables, live toasts...),
    # in the default locale and a translated one, and each drawer/dialog
    # fragment the script loads keeps its heading and labels too.
    class AdminAccessibilityTest < AdminTestCase
      include AdminPagePaths

      test 'every screen is clean, in English and Macedonian' do
        failures = %w[en mk].flat_map do |locale|
          screens = paths.map { |path| get(pf(path), params: { locale: locale }) && [path, response.body] }
          (screens + extra_screens(locale: locale)).flat_map do |label, body|
            A11yLint.new(body).problems.map { |problem| "#{locale} #{label}: #{problem}" }
          end
        end
        assert_empty failures, failures.join("\n")
      end

      test 'the Permission Set audit tab is clean with the trail on' do
        previous = PermissionForge.configuration.audit_trail_enabled
        PermissionForge.configuration.audit_trail_enabled = true
        get pf("/permission_sets/#{@set.id}?tab=audit")
        assert_response :success
        assert_select 'a.pf-table__link', minimum: 1
        assert_empty A11yLint.new(response.body).problems
      ensure
        PermissionForge.configuration.audit_trail_enabled = previous
      end

      test 'a drawer loaded into the dialog keeps its labels and heading order' do
        drawers = paths.grep(%r{/(fields|actions|rules)/|/new\z|/delete\z|/edit\z})
        failures = drawers.flat_map do |path|
          get pf(path), headers: { 'X-PF-Fragment' => '1' }
          A11yLint.new("<!doctype html><html lang=en><title>x</title><body><main>#{response.body}</main>", fragment: true)
                  .problems.map { |problem| "#{path}: #{problem}" }
        end
        assert_empty failures, failures.join("\n")
      end

      test 'the lint itself catches what it is for' do
        bad = <<~HTML
          <!doctype html><html><title></title><body><h2>x</h2><h4>y</h4>
          <input name=q><button></button><a href="/x"></a><img src=a.png>
          <table><tr><td>1</td></tr></table><div class=pf-toast>hi</div>
          <a href=/y aria-pressed=true role=row>y</a><div id=a></div><div id=a></div><div aria-labelledby=nope></div></body></html>
        HTML
        problems = A11yLint.new(bad).problems.join("\n")
        ['no lang', '<title> is empty', '0 <h1>', 'jumps from h2 to h4', 'has no label', '<button> has no text', '<a> has no text',
         'has no alt', 'not a link role', 'no header cells', 'not a live region', 'aria-pressed', 'duplicate id', 'missing #nope',
         '<main> landmarks'].each do |expected|
          assert_includes problems, expected
        end
        raw = '<!doctype html><html lang=en><title>{"one" => "Review %{count} change"}</title><body><main><h1>x</h1></main></body></html>'
        assert_includes A11yLint.new(raw).problems.join("\n"), '<title> is a raw value'
      end
    end
  end
end
