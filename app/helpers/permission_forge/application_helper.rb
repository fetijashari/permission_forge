module PermissionForge
  # @api private
  module ApplicationHelper
    include PermissionForge::UiHelper
    include PermissionForge::BadgesHelper
    include PermissionForge::PeopleHelper
    include PermissionForge::LabelsHelper
    include PermissionForge::SentencesHelper
    include PermissionForge::ConditionsHelper
    include PermissionForge::RuleProblemsHelper
    include PermissionForge::AuditSentencesHelper
    include PermissionForge::ChangesHelper
    include PermissionForge::AuditHelper
    include PermissionForge::AuditRecordsHelper
    include PermissionForge::AuditAttributionHelper
    include PermissionForge::SettingsHelper

    # Sidebar link; the current section gets aria-current="page".
    def pf_nav_link(label, path, badge: nil, badge_label: nil, exact: false)
      current = exact ? request.path == path : request.path.start_with?(path)
      body = [content_tag(:span, label, class: 'pf-nav__label')]
      body << content_tag(:span, badge, class: 'pf-nav__badge', 'aria-label': badge_label) if badge.to_i.positive?
      link_to safe_join(body), path, class: 'pf-nav__link', 'aria-current': (current ? 'page' : nil)
    end

    def pf_status_badge(active)
      if active
        pf_badge("● #{t('permission_forge.shared.active')}", variant: :grant)
      else
        pf_badge("○ #{t('permission_forge.shared.inactive')}", variant: :off)
      end
    end

    # Host app name shown in the "Back to …" link under the logo.
    def pf_app_name
      PermissionForge.configuration.admin_app_name.presence || pf_default_app_name
    end

    # Where "Back to <app>" leads: config.admin_back_url, else the host app's
    # root route, else "/".
    def pf_back_to_app_url
      target = PermissionForge.configuration.admin_back_url
      return target.call(self).to_s if target.respond_to?(:call)
      return target.to_s if target.present?

      main_app.respond_to?(:root_path) ? main_app.root_path : '/'
    rescue StandardError
      '/'
    end

    def pf_back_to_app_label
      name = pf_app_name
      name ? t('permission_forge.shared.sidebar.back_to_app', app: name) : t('permission_forge.shared.sidebar.back_to_app_generic')
    end

    def pf_default_app_name
      return nil unless defined?(Rails) && Rails.application

      Rails.application.class.module_parent_name.to_s.titleize.presence
    end

    # @deprecated Use {UiHelper#pf_relative}. Read Rails' datetime.distance_in_words keys
    #   (English without rails-i18n); now the same as pf_relative, removed in 0.16.
    def pf_time_ago(time)
      PermissionForge::Deprecation.warn('pf_time_ago is deprecated; use pf_relative', key: :pf_time_ago)
      pf_relative(time)
    end

    def pf_available_locales
      allowed = PermissionForge.configuration.available_locales || PermissionForge::BUNDLED_LOCALES
      Array(allowed).map(&:to_sym)
    end

    LOCALE_LABELS = {
      en: 'English',
      sq: 'Shqip',
      mk: 'Makedonski'
    }.freeze

    def pf_locale_label(locale)
      LOCALE_LABELS[locale.to_sym] || locale.to_s.upcase
    end

    # Builds a locale-switch link for the CURRENT path without reflecting
    # arbitrary query parameters. Reflecting all of request.query_parameters
    # through url_for lets an attacker inject reserved keys (host, protocol,
    # script_name) and turn the switcher into an off-site link. We keep only the
    # current path and set the (validated) locale.
    def pf_locale_switch_path(locale)
      loc = locale.to_s
      loc = I18n.default_locale.to_s unless pf_available_locales.map(&:to_s).include?(loc)
      "#{request.path}?locale=#{CGI.escape(loc)}"
    end

    # Display label for a user in the assignment dropdown: the person's
    # label (Admin::PersonLabel — `config.user_label_formatter`, else name
    # then email, else "User"), with the email in parentheses when the
    # label is a name and no formatter is configured. The id is appended in
    # `#<id>` form to keep labels unique.
    def pf_user_option_label(user)
      label = pf_person(user)
      return "#{t('permission_forge.shared.user')} ##{user.id}" if label.fallback?

      email = label.secondary unless PermissionForge.configuration.user_label_formatter
      base = email ? "#{label.name} (#{email})" : label.name
      "#{base} ##{user.id}"
    end

    private

    # A user attribute for the admin's labels, read raw-column-first past
    # MaskedAttributes (Admin::PersonLabel.raw_value: the one definition).
    def pf_raw_user_attribute(user, attr)
      Admin::PersonLabel.raw_value(user, attr)
    end
  end
end
