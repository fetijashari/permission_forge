module PermissionForge
  # Badges, Permission Set chips, field level badges and mask previews.
  # Every class is pf- prefixed; no inline styles (strict-CSP friendly).
  #
  # @api private
  module BadgesHelper
    # The level-badge colour of a state that is not a field level
    # (Admin::StateLabel kinds :effective and :action), by its kind.
    LEVEL_BADGE_CSS = {
      effective: { 'hidden_by_muting' => 'muted' },
      action: { 'permitted' => 'edit', 'not_permitted' => 'none', 'blocked' => 'muted', 'unchanged' => 'leave',
                'none' => 'none' }
    }.freeze

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

    # The Locked badge. With a record: only when it is locked (pf_locked?,
    # the chain), so a row's badge and its disabled controls agree.
    def pf_lock_badge(record = nil, title: pf_ui('locked.title'))
      return if !record.nil? && !pf_locked?(record)

      pf_badge([pf_lock_icon, pf_state(:lock, :locked).word], title: title)
    end

    # Whether a record is locked: itself, its Resource, its Permission Set or
    # (a membership) its group flagged is_editable: false — Admin::EditableLock,
    # the one definition the controllers refuse by.
    def pf_locked?(record)
      PermissionForge::Admin::EditableLock.locked?(record)
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
      badges << pf_lock_badge(permission_set)
      safe_join(badges, ' ')
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
      safe_join([content_tag(:span, "#{CHIP_PREFIXES[state]}#{pf_record_name(permission_set)}"),
                 (content_tag(:span, pf_ui(suffix_key), class: 'pf-chip__suffix') if suffix_key)].compact, ' ')
    end

    # A field's level for one person (an EffectiveAccess::FieldOutcome), the
    # same in their Effective access row, its Why panel and the field
    # drawer's "Explain for": hidden by a Muting Permission Set reads
    # "⊘ Hidden by muting", never the neutral "∅ Hidden" of a field no set
    # grants. `sample: true` adds a masked value's preview (the Why panel).
    def pf_effective_field_badge(field, sample: false)
      return pf_level_badge('hidden_by_muting', kind: :effective) if field.hidden_by_muting?

      masked = field.level == 'masked'
      pf_level_badge(field.level, strategy: (field.mask_strategy if masked), sample_for: (field.name if masked && sample))
    end

    # [glyph, sentence] for the entry along a single-table-inheritance chain
    # that decides a person's field (EffectiveAccess::FieldOutcome#decided_by,
    # #unreadable), or nil when the resource's own entry decides and grants
    # Read: the Why panel and the field drawer's "Explain for" both say it.
    def pf_field_chain_reason(field)
      base = field.decided_by
      if field.unreadable
        return ['∅', t('permission_forge.people.effective_why.field_own_unreadable')] unless base

        return ['∅', t('permission_forge.people.effective_why.field_base_unreadable', resource: pf_resource_label(base))]
      end
      ['↑', t('permission_forge.people.effective_why.field_decided_by', resource: pf_resource_label(base))] if base
    end

    # A level as a badge ("•• Masked (Email) · j***@acme.com"): a field level
    # by default, or a state of another kind (Admin::StateLabel) drawn the
    # same way — an effective outcome, an action state.
    def pf_level_badge(level, strategy: nil, sample_for: nil, kind: :field_level)
      label = PermissionForge::Admin::StateLabel.for(kind, level)
      text = label.word
      if %w[masked mask].include?(label.state) && strategy.present?
        text = "#{text} (#{pf_mask_strategy_label(strategy)})"
        text = "#{text} · #{pf_mask_preview(sample_for, strategy)}" if sample_for
      end
      css = LEVEL_BADGE_CSS.fetch(kind.to_sym, {}).fetch(label.state, label.state)
      content_tag(:span, "#{label.glyph} #{text}", class: "pf-level-badge pf-level-badge--#{css}")
    end

    # The word of a field level (Admin::StateLabel, kind :field_level).
    def pf_level_label(level)
      pf_state(:field_level, level).word
    end

    # The caption of a Fields tab filter: a level's word, Sensitive, or "All".
    def pf_field_filter_label(filter)
      case filter.to_s
      when 'all' then t('permission_forge.resources.fields_tab.filters.all')
      when 'sensitive' then pf_ui('badges.sensitive')
      when 'unconfigured' then pf_state(:field_level, :none).word
      else pf_level_label(filter)
      end
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
