module PermissionForge
  # @api private
  module ApplicationHelper
    include PermissionForge::UiHelper
    include PermissionForge::BadgesHelper
    include PermissionForge::PeopleHelper
    include PermissionForge::SentencesHelper
    include PermissionForge::AuditSentencesHelper
    include PermissionForge::ChangesHelper
    include PermissionForge::AuditHelper
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

    def pf_time_ago(time)
      return t('permission_forge.shared.time_nil') if time.nil?

      t('permission_forge.shared.time_ago', time: time_ago_in_words(time))
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

    # Display label for a user in the assignment dropdown.
    #
    # Honors `config.user_label_formatter` if configured. Otherwise tries
    # `:name`, `:full_name`, `:display_name`, then composes `first_name`/`last_name`,
    # adds the email (`Admin::PersonLabel::EMAIL_ATTRIBUTES`: `email`, then
    # `email_address`), and finally falls back to `User #<id>`.
    # The id is appended in `#<id>` form to keep labels unique.
    def pf_user_option_label(user)
      formatter = PermissionForge.configuration.user_label_formatter
      base = formatter ? formatter.call(user).to_s.strip : pf_default_user_label(user)
      base = 'User' if base.blank?
      "#{base} ##{user.id}"
    end

    private

    def pf_default_user_label(user)
      name = pf_first_present(user, :name, :full_name, :display_name) || pf_compose_name(user)
      email = pf_first_present(user, *Admin::PersonLabel::EMAIL_ATTRIBUTES)
      pf_format_name_and_email(name, email)
    end

    def pf_compose_name(user)
      [pf_raw_user_attribute(user, :first_name), pf_raw_user_attribute(user, :last_name)]
        .compact.map { |part| part.to_s.strip }.reject(&:empty?).join(' ').presence
    end

    def pf_format_name_and_email(name, email)
      return "#{name} (#{email})" if name && email
      return name if name
      return email if email

      t('permission_forge.shared.user')
    end

    def pf_first_present(user, *methods)
      methods.each do |m|
        value = pf_raw_user_attribute(user, m).to_s.strip
        return value unless value.empty?
      end
      nil
    end

    # Reads a user attribute for the admin assignment dropdown, bypassing
    # MaskedAttributes. The dropdown is permission-management infrastructure —
    # admins need to see user labels to assign permissions — so it must not be
    # subject to the same field masking as ordinary reads.
    #
    # Real columns are read via `read_attribute_before_type_cast` FIRST: the
    # public getter on a masked model routes every call through
    # AttributeAccessGuard (a per-attribute permission lookup) and can hand
    # back a masked or hidden sentinel — wrong for these labels and, across a
    # large dropdown, the difference between milliseconds and tens of seconds.
    # Virtual attributes (host-app methods like a composed `display_name`)
    # still resolve via the public method, as does a column whose raw value is
    # blank. Consequence: a host method overriding a *populated* column is not
    # consulted here — `config.user_label_formatter` is the escape hatch for
    # custom label logic.
    def pf_raw_user_attribute(user, attr)
      attr_name = attr.to_s
      if pf_readable_column?(user, attr_name)
        stored = user.read_attribute_before_type_cast(attr_name)
        return stored if stored.to_s.strip.present?
      end

      user.try(attr)
    end

    # True when `attr_name` is a real, loaded column on an AR-like user —
    # i.e., safe to read raw. Guards against partial SELECTs from a custom
    # user_list_resolver, where an unloaded column must not be touched.
    def pf_readable_column?(user, attr_name)
      klass = user.class
      klass.respond_to?(:column_names) &&
        klass.column_names.include?(attr_name) &&
        user.respond_to?(:read_attribute_before_type_cast) &&
        (!user.respond_to?(:has_attribute?) || user.has_attribute?(attr_name))
    end
  end
end
