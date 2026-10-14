require 'test_helper'

module PermissionForge
  module Html
    # The engine serves its own CSS/JS/brand files (no host asset pipeline).
    class AssetsTest < ActionDispatch::IntegrationTest
      test 'serves allow-listed files with the right type' do
        { 'pf_admin.css' => 'text/css', 'pf_admin.js' => 'text/javascript', 'logo-light.svg' => 'image/svg+xml',
          'favicon.ico' => 'image/x-icon' }.each do |file, type|
          get "/permission_forge/pf-assets/#{file}"

          assert_response :success
          assert_equal type, response.media_type
          assert_equal 'nosniff', response.headers['X-Content-Type-Options']
        end
      end

      test 'fingerprinted URLs are cached forever' do
        digest = PermissionForge::AssetsController.digest('pf_admin.css')
        get "/permission_forge/pf-assets/pf_admin.css?v=#{digest}"

        assert_match 'immutable', response.headers['Cache-Control']
      end

      test 'unknown files are not served' do
        get '/permission_forge/pf-assets/secrets.yml'

        assert_response :not_found
      end

      test 'the stylesheet only targets namespaced selectors' do
        css = File.read(PermissionForge::AssetsController::ROOT.join('pf_admin.css'))
        selectors = css.gsub(%r{/\*.*?\*/}m, '').scan(/([^{}]+)\{/).flatten.map(&:strip)
                       .reject { |s| s.start_with?('@') || s.match?(/\A(from|to|\d+%)\z/) }
        offenders = selectors.flat_map { |s| split_top_level(s) }
                             .reject { |s| s.start_with?('.pf-') || s.match?(/\A\.pf-root\b/) }

        assert_empty offenders
      end

      private

      # Splits a selector list on commas that are not inside parentheses.
      def split_top_level(list)
        depth = 0
        parts = ['']
        list.each_char do |ch|
          depth += 1 if ch == '('
          depth -= 1 if ch == ')'
          ch == ',' && depth.zero? ? parts << '' : parts[-1] += ch
        end
        parts.map(&:strip)
      end
    end
  end
end
