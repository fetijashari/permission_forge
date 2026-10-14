module PermissionForge
  # Badges, Permission Set chips, field level badges and mask previews.
  # Every class is pf- prefixed; no inline styles (strict-CSP friendly).
  #
  # @api private
  module BadgesHelper
    LEVEL_GLYPHS = { 'hidden' => '∅', 'masked' => '••', 'read' => '◉', 'edit' => '✎', 'leave' => '–',
                     'mask' => '••', 'hide' => '⊘', 'muted' => '⊘', 'none' => '–' }.freeze

    MASK_SAMPLES = [
      [/email/, 'james.walker@acme.com'],
      [/iban|bank|account|card/, 'DE89 3704 0044 0532 0130 00'],
      [/phone|mobile|fax|tel/, '+383 44 123 456'],
      [/cents|salary|amount|price|value/, '4 200,00 €'],
      [/national|ssn|social/, '1234567890'],
      [/birth|dob/, '1988-04-17'],
      [/vat|tax/, 'XK810123456'],
      [/address|street|city|zip|postal/, 'Rruga Agim Ramadani 15']
    ].freeze
    DEFAULT_MASK_SAMPLE = 'James Walker'.freeze

    CHIP_PREFIXES = { muting: '⊘ ', inactive: '○ ' }.freeze
    CHIP_SUFFIX_KEYS = { inactive: 'badges.off', expired: 'badges.expired' }.freeze

    # --- badges ---------------------------------------------------------------

    # Options: title:, href:, square: (bool), extra: (additional classes).
    def pf_badge(text, variant: :default, **opts)
      classes = ['pf-badge', ("pf-badge--#{variant}" unless variant.to_s == 'default'),
                 ('pf-badge--square' if opts[:square]), opts[:extra]].compact.join(' ')
      content = safe_join(Array(text))
      href = opts[:href]
      return link_to(content, href, class: classes, title: opts[:title]) if href

      content_tag(:span, content, class: classes, title: opts[:title])
    end

    def pf_lock_badge(title: pf_ui('locked.title'))
      pf_badge([pf_lock_icon, pf_ui('badges.locked')], title: title)
    end

    def pf_off_badge
      content_tag(:span, "○ #{pf_ui('badges.off')}", class: 'pf-badge pf-badge--off')
    end

    def pf_fail_open?
      !PermissionForge.configuration.conditional_sets_strict_mode
    end

    def pf_fail_open_badge(long: false)
      text = long ? pf_ui('badges.fail_open_long') : pf_ui('badges.fail_open')
      pf_badge("⚠ #{text}", variant: :failopen, href: pf_setting_path('conditional_sets_strict_mode'),
                            title: pf_ui('badges.fail_open_title'))
    end

    def pf_set_badges(permission_set)
      badges = []
      badges << pf_badge("⊘ #{pf_ui('badges.muting')}", variant: :muting) if permission_set.is_muting
      if permission_set.conditional?
        badges << pf_badge("◷ #{pf_ui('badges.conditional')}", variant: :conditional,
                                                               title: pf_condition_sentence(permission_set))
        badges << pf_fail_open_badge if pf_fail_open?
      end
      badges << pf_lock_badge if pf_locked_record?(permission_set)
      safe_join(badges, ' ')
    end

    def pf_locked_record?(record)
      record.respond_to?(:is_editable) && record.is_editable == false
    end

    # Permission Set chip. state: :normal / :inactive / :expired (auto from set).
    def pf_set_chip(permission_set, large: false, href: :auto, expired: false)
      state = pf_set_chip_state(permission_set, expired)
      classes = ['pf-chip', ('pf-chip--lg' if large), ("pf-chip--#{state}" unless state == :normal)].compact.join(' ')
      body = pf_set_chip_body(permission_set, state)
      href = permission_forge.permission_set_path(permission_set) if href == :auto
      href ? link_to(body, href, class: classes) : content_tag(:span, body, class: classes)
    end

    def pf_set_chip_state(permission_set, expired)
      return :expired if expired
      return :inactive unless permission_set.is_active

      permission_set.is_muting ? :muting : :normal
    end

    def pf_set_chip_body(permission_set, state)
      suffix_key = CHIP_SUFFIX_KEYS[state]
      safe_join([content_tag(:span, "#{CHIP_PREFIXES[state]}#{permission_set.name}"),
                 (content_tag(:span, pf_ui(suffix_key), class: 'pf-chip__suffix') if suffix_key)].compact, ' ')
    end

    # Effective/configured field level badge ("•• Masked · j***@acme.com").
    def pf_level_badge(level, strategy: nil, sample_for: nil, label: nil)
      level = level.to_s
      text = label || pf_level_label(level)
      if %w[masked mask].include?(level) && strategy.present?
        text = "#{text} (#{pf_mask_strategy_label(strategy)})"
        text = "#{text} · #{pf_mask_preview(sample_for, strategy)}" if sample_for
      end
      content_tag(:span, "#{LEVEL_GLYPHS.fetch(level, '–')} #{text}", class: "pf-level-badge pf-level-badge--#{level}")
    end

    def pf_level_label(level)
      pf_ui("levels.#{level}")
    end

    def pf_mask_strategy_label(strategy)
      t("permission_forge.ui.mask_strategies.#{strategy}", default: strategy.to_s)
    end

    def pf_mask_strategies
      PermissionForge::Services::MaskValue.strategies.keys.map(&:to_s)
    end

    def pf_custom_mask_strategy?(strategy)
      !PermissionForge::Services::MaskValue::BUILT_IN_STRATEGIES.key?(strategy.to_s)
    end

    def pf_mask_sample(column)
      name = column.to_s
      MASK_SAMPLES.find { |pattern, _| name.match?(pattern) }&.last || DEFAULT_MASK_SAMPLE
    end

    # Runs the real MaskValue strategy on a sample value, so previews always
    # match what people will see.
    def pf_mask_preview(column, strategy)
      PermissionForge::Services::MaskValue.call(pf_mask_sample(column), strategy: strategy.to_s)
    rescue StandardError
      '••••••••'
    end
  end
end
