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
    end
  end
end
