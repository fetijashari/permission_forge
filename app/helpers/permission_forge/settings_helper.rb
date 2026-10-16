module PermissionForge
  # Renders configuration values on the read-only Settings page by type.
  # Secrets show only "Set"/"Not set"; code hooks only default/custom/not set.
  #
  # @api private
  module SettingsHelper
    SECONDS_UNITS = [[86_400, :days], [3600, :hours], [60, :minutes]].freeze

    # Current-value renderer per setting type (private methods taking the row);
    # any other type renders as a scalar.
    VALUE_RENDERERS = {
      bool: :pf_setting_bool, enum: :pf_setting_enum, num: :pf_setting_number,
      list: :pf_setting_list, names: :pf_setting_list, map: :pf_setting_map,
      secret: :pf_setting_secret, hook: :pf_setting_hook
    }.freeze

    # Default-value text per setting type; any other type renders as a scalar.
    DEFAULT_RENDERERS = {
      bool: :pf_setting_default_bool, secret: :pf_setting_default_secret, hook: :pf_setting_default_hook,
      list: :pf_setting_default_list, names: :pf_setting_default_list, map: :pf_setting_default_list,
      num: :pf_setting_default_number
    }.freeze

    def pf_setting_value(row)
      send(VALUE_RENDERERS.fetch(row.type, :pf_setting_scalar), row)
    end

    def pf_setting_default(row)
      send(DEFAULT_RENDERERS.fetch(row.type, :pf_setting_default_scalar), row)
    end

    # Compact "key = value" form for the health summary.
    def pf_setting_inline_value(row)
      case row.type
      when :secret then row.value ? t('permission_forge.settings.values.set') : t('permission_forge.settings.values.not_set')
      when :hook then t("permission_forge.settings.values.hook_#{row.hook_state}")
      when :enum then ":#{row.value}"
      else row.value.inspect
      end
    end

    private

    def pf_setting_bool(row)
      if row.value
        content_tag(:span, "● #{t('permission_forge.settings.values.on')}", class: 'pf-pill pf-pill--on')
      else
        content_tag(:span, "○ #{t('permission_forge.settings.values.off')}", class: 'pf-pill')
      end
    end

    def pf_setting_enum(row)
      options = Array(row.definition.options).map(&:to_s)
      options << row.value unless options.include?(row.value.to_s)
      pills = options.map do |opt|
        current = opt == row.value.to_s
        content_tag(:code, opt, class: "pf-pill pf-pill--opt#{' pf-pill--current' if current}", 'aria-current': (current ? 'true' : nil))
      end
      content_tag(:span, safe_join(pills, ' '), class: 'pf-row pf-row--tight')
    end

    def pf_setting_number(row)
      value = row.value
      return content_tag(:span, t('permission_forge.settings.values.nil'), class: 'pf-text-3') if value.nil?

      content_tag(:span, pf_setting_number_text(value, row.definition.unit), class: 'pf-tabular pf-fw-600')
    end

    def pf_setting_number_text(value, unit)
      return t('permission_forge.settings.values.nil') if value.nil?
      return "#{value} #{t("permission_forge.settings.units.#{unit}", count: value)}" unless unit == :seconds

      human = SECONDS_UNITS.find { |secs, _| (value % secs).zero? && value >= secs }
      text = "#{value} s"
      human ? "#{text} (#{t("permission_forge.settings.units.#{human.last}", count: value / human.first)})" : text
    end

    def pf_setting_list(row)
      value = row.value
      return content_tag(:span, pf_setting_nil_text(row), class: 'pf-text-3') if value.nil?
      return content_tag(:span, t('permission_forge.settings.values.empty'), class: 'pf-text-3') if value.empty?

      content_tag(:span, safe_join(value.map { |v| content_tag(:code, v, class: 'pf-pill pf-pill--opt') }, ' '),
                  class: 'pf-row pf-row--tight')
    end

    def pf_setting_map(row)
      value = row.value
      return content_tag(:span, t('permission_forge.settings.values.empty'), class: 'pf-text-3') if value.blank?

      content_tag(:span, safe_join(value.map { |k, v| content_tag(:code, "#{k} → #{v}") }), class: 'pf-map')
    end

    def pf_setting_secret(row)
      if row.value
        content_tag(:span, "● #{t('permission_forge.settings.values.set')}", class: 'pf-pill pf-pill--on')
      else
        content_tag(:span, "○ #{t('permission_forge.settings.values.not_set')} · #{t('permission_forge.settings.values.never_displayed')}",
                    class: 'pf-pill')
      end
    end

    def pf_setting_hook(row)
      state = row.hook_state
      css = state == :custom ? 'pf-pill pf-pill--on' : 'pf-pill'
      content_tag(:span, t("permission_forge.settings.values.hook_#{state}"), class: css)
    end

    def pf_setting_scalar(row)
      value = row.value
      return content_tag(:span, pf_setting_nil_text(row), class: 'pf-text-3') if value.nil?

      content_tag(:code, value.to_s, class: 'pf-mono')
    end

    def pf_setting_default_bool(row)
      row.default ? t('permission_forge.settings.values.on') : t('permission_forge.settings.values.off')
    end

    def pf_setting_default_secret(_row)
      t('permission_forge.settings.values.not_set')
    end

    def pf_setting_default_hook(row)
      t("permission_forge.settings.values.hook_#{row.default}")
    end

    def pf_setting_default_list(row)
      values = Array(row.default)
      return t('permission_forge.settings.values.empty') if values.empty?

      values.map { |v| Array(v).join(' → ') }.join(', ')
    end

    def pf_setting_default_number(row)
      pf_setting_number_text(row.default, row.definition.unit)
    end

    def pf_setting_default_scalar(row)
      value = row.default
      value.nil? ? pf_setting_nil_text(row) : value.to_s
    end

    def pf_setting_nil_text(row)
      case row.definition.nil_label
      when :disabled then t('permission_forge.settings.values.disabled')
      when :default then t('permission_forge.settings.values.hook_default')
      else t('permission_forge.settings.values.nil')
      end
    end
  end
end
