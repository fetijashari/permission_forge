require_relative 'admin_test_case'
require_relative 'admin_page_paths'

module PermissionForge
  module Html
    # Every admin screen renders, in every bundled locale, with no missing
    # translations, no inline styles/scripts (strict CSP) and only pf- classes.
    class AdminPagesTest < AdminTestCase
      include AdminPagePaths

      test 'every screen renders cleanly in every bundled locale' do
        PermissionForge::BUNDLED_LOCALES.each do |locale|
          paths.each do |path|
            get pf(path), params: { locale: locale }

            assert_response :success, "#{locale} #{path}"
            assert_no_missing_translations
          end
        end
      end

      test 'markup is CSP-safe and namespaced, on every screen and every re-rendered form' do
        screens = paths.map { |path| get(pf(path)) && [path, response.body] } + error_screens
        screens.each do |path, body|
          assert_no_match(/\sstyle="/, body, "inline style on #{path}")
          assert_no_match(/<script(?![^>]*\ssrc=)/, body, "inline script on #{path}")
          assert_no_match(/\son[a-z]+="/, body, "inline handler on #{path}")
          classes = body.scan(/class="([^"]*)"/).flatten.flat_map(&:split).uniq
          assert_empty classes.reject { |c| c.start_with?('pf-') }, "unprefixed classes on #{path}"
        end
      end

      test 'fragment requests render without the layout' do
        get pf("/people/#{@ana.id}/remove_all"), headers: { 'X-PF-Fragment' => '1' }

        assert_response :success
        assert_no_match(/<html/, response.body)
        assert_match(/data-pf-role="alertdialog"/, response.body)
      end

      test 'layout links engine-served assets with digests and the brand' do
        get pf('/')

        assert_match %r{/permission_forge/pf-assets/pf_admin\.css\?v=\h{12}}, response.body
        assert_match %r{/permission_forge/pf-assets/pf_admin\.js\?v=\h{12}}, response.body
        assert_match %r{pf-assets/logo-light\.svg}, response.body
        assert_match %r{pf-assets/favicon\.svg}, response.body
        assert_match(/class="pf-root"/, response.body)
      end

      test 'the sidebar links back to the host app' do
        get pf('/')
        assert_select 'a.pf-back-link[href="/"]', text: /Dummy/

        PermissionForge.configuration.admin_app_name = 'Acme CRM'
        PermissionForge.configuration.admin_back_url = ->(_view) { '/dashboard' }
        get pf('/')
        assert_select 'a.pf-back-link[href="/dashboard"]', text: /Back to Acme CRM/
        assert_select 'nav.pf-sidebar > .pf-sidebar__inner'
      end

      test 'first run and all-good states' do
        PermissionForge::PermissionSet.destroy_all
        get pf('/')
        assert_match I18n.t('permission_forge.home.index.first_run.title'), response.body

        create_permission_set(name: 'Only').tap { |ps| create_permission_set_user(user: @bo, permission_set: ps) }
        PermissionForge.configuration.unconfigured_field_strategy = :block
        get pf('/')
        assert_match I18n.t('permission_forge.home.index.all_good.title'), response.body
      end
    end
  end
end
