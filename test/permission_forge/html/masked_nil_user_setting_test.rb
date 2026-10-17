# frozen_string_literal: true

require_relative 'admin_test_case'

module PermissionForge
  module Html
    # The Settings page shows masked_attributes_nil_user_strategy with its
    # three values and what each does, in every locale (GitHub #11). The
    # admin itself is a web request with nobody signed in here (HTTP Basic):
    # it renders under :hide_in_requests.
    class MaskedNilUserSettingTest < AdminTestCase
      KEY = 'masked_attributes_nil_user_strategy'

      teardown { I18n.locale = I18n.default_locale }

      test 'the Settings page lists bypass, hide_in_requests and hide, marks the current one and explains them in en, sq and mk' do
        PermissionForge.configuration.masked_attributes_nil_user_strategy = :hide_in_requests

        %w[en sq mk].each do |locale|
          get pf('/settings'), params: { locale: locale }

          assert_response :success
          assert_no_missing_translations
          assert_select "#set-#{KEY} .pf-pill--opt", count: 3
          assert_equal %w[bypass hide_in_requests hide], css_select("#set-#{KEY} .pf-pill--opt").map(&:text)
          assert_select "#set-#{KEY} .pf-pill--current", text: 'hide_in_requests'
          I18n.with_locale(locale) do
            desc = I18n.t("permission_forge.settings.items.#{KEY}.desc")
            assert_includes desc, 'hide_in_requests', locale
            assert_select "#set-#{KEY} .pf-setting__about", text: /#{Regexp.escape(desc.split.first(3).join(' '))}/
            assert_select "#set-#{KEY} .pf-text-grant", text: I18n.t("permission_forge.settings.oks.#{KEY}")
          end
        end
      end

      test 'the row is secure under :hide_in_requests and :hide, neutral under :bypass' do
        { hide_in_requests: true, hide: true, bypass: false }.each do |strategy, secure|
          PermissionForge.configuration.masked_attributes_nil_user_strategy = strategy
          row = Admin::SettingsCatalog.new.row(KEY.to_sym)

          assert_equal secure, row.ok?, strategy
          assert_not row.warn?, strategy
        end
      end
    end
  end
end
