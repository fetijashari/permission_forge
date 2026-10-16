require 'test_helper'

module PermissionForge
  module Html
    # pf_admin.js is progressive enhancement under a strict CSP: block-scoped
    # declarations only, and no markup string is ever written into the page.
    class AdminScriptHygieneTest < ActiveSupport::TestCase
      SCRIPT = PermissionForge::AssetsController::ROOT.join('pf_admin.js')

      def code
        @code ||= File.read(SCRIPT).gsub(%r{/\*.*?\*/}m, '').gsub(%r{^\s*//.*$}, '')
      end

      test 'no var declarations' do
        assert_no_match(/\bvar\s/, code)
      end

      test 'no HTML-string sinks and no eval (a code-style rule: fragments go in through setContent, which is not a sanitiser)' do
        ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'createContextualFragment', 'eval(', 'new Function'].each do |sink|
          assert_not_includes code, sink, "pf_admin.js uses #{sink}"
        end
      end

      test 'no inline handlers are ever attached through attributes' do
        assert_no_match(/setAttribute\(\s*['"]on/i, code)
      end

      # Review R4 P2-10: the rule preview aborts the request a newer input
      # replaces (a late answer never overwrites a newer one) and never puts
      # a redirect's page or a whole document into the panel.
      test 'the rule preview aborts a stale request and injects fragments only' do
        preview = code[/function previewRule\(form\) \{.*?\n  \}\n/m]

        assert preview, 'previewRule is where it was'
        assert_includes preview, 'new AbortController()'
        assert_includes preview, '.abort()'
        assert_includes preview, 'signal:'
        assert_includes preview, 'res.redirected'
        assert_match(/<html/, preview, 'a whole document is not a fragment')
        assert_includes preview, 'setContent(panel'
      end
    end
  end
end
