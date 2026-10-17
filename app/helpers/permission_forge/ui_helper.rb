module PermissionForge
  # Building blocks shared by every admin screen: assets, text, dates, state
  # cells, banners, footers, tabs, frames. Badges/chips live in BadgesHelper,
  # people/assignment cells in PeopleHelper.
  # Every class is pf- prefixed; no inline styles (strict-CSP friendly).
  #
  # @api private
  module UiHelper
    # --- assets ---------------------------------------------------------------

    def pf_asset_url(file)
      permission_forge.pf_asset_path(file: file, v: PermissionForge::AssetsController.digest(file))
    end

    # ` nonce="…"` when the host app runs a CSP with nonces, else nothing.
    def pf_nonce_attribute(_kind = :script)
      nonce = respond_to?(:content_security_policy_nonce) ? content_security_policy_nonce : nil
      nonce.present? ? tag.attributes(nonce: nonce) : ''
    rescue StandardError
      ''
    end

    def pf_lock_icon
      tag.svg(class: 'pf-lock', viewBox: '0 0 16 16', fill: 'none', stroke: 'currentColor', 'stroke-width': '1.6',
              'aria-hidden': 'true', focusable: 'false') do
        safe_join([tag.rect(x: 3, y: 7, width: 10, height: 7, rx: 1.5), tag.path(d: 'M5.5 7V5a2.5 2.5 0 0 1 5 0v2')])
      end
    end

    # The attributes, only when the condition holds: `<input <%= pf_attrs_when(error, aria: { invalid: true }) %>>`.
    # Built by `tag.attributes`, so every value is escaped; nothing is marked safe by hand.
    def pf_attrs_when(condition, **attributes)
      condition ? tag.attributes(**attributes) : ''
    end

    # --- text helpers ---------------------------------------------------------

    def pf_ui(key, **)
      t("permission_forge.ui.#{key}", **)
    end

    # A translation whose interpolated values may be markup (a SafeBuffer:
    # a name marked as host data) although its key does not end in `_html`:
    # the block translates with a marker in place of each value, and the
    # pieces are joined with safe_join — the translation's own text escaped,
    # the markup kept, nothing marked safe by hand. The `t(...)` stays in the
    # caller (i18n-tasks sees the key).
    #
    #   pf_t_markup(set: pf_host_data(name)) { |held| t('.flag_granted', **held, flag: word) }
    #
    # A marker no value was given for (text that happens to hold one, such
    # as a stored value interpolated as text) is left as written, escaped.
    #
    # @yieldparam held [Hash{Symbol => String}] the markers, by value name
    # @return [ActiveSupport::SafeBuffer]
    def pf_t_markup(**values)
      held = values.to_h { |name, _| [name, "\u0001#{name}\u0001"] }
      by_name = values.transform_keys(&:to_s)
      pieces = yield(held).to_s.split(/\u0001(\w+)\u0001/)
      safe_join(pieces.each_with_index.map { |piece, index| index.odd? ? by_name.fetch(piece) { "\u0001#{piece}\u0001" } : piece })
    end

    # "Bob, Carol and Dan" in the page's language (Admin::ListSentence): never
    # a bare to_sentence, whose connectors stay English without rails-i18n.
    def pf_to_sentence(items, **)
      PermissionForge::Admin::ListSentence.call(items, **)
    end

    # #pf_to_sentence for items that carry markup (a set named with its
    # Resource as host data): each item is kept as it is (#pf_t_markup).
    def pf_markup_sentence(items)
      values = items.each_with_index.to_h { |item, index| [:"item#{index}", item] }
      pf_t_markup(**values) { |held| pf_to_sentence(held.values) }
    end

    def pf_people_text(count)
      pf_ui('people_count', count: count)
    end

    MONTH_KEYS = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze

    # "12 Mar 2026" / "12 Mar" using the engine's own month names (no
    # dependency on rails-i18n being installed in the host app).
    def pf_date(value, year: true)
      return pf_ui('dates.never') if value.nil?

      date = value.to_date
      month = t("permission_forge.ui.months.#{MONTH_KEYS[date.month - 1]}")
      year ? "#{date.day} #{month} #{date.year}" : "#{date.day} #{month}"
    end

    def pf_datetime(value)
      return pf_ui('dates.never') if value.nil?

      "#{pf_date(value)} · #{value.in_time_zone.strftime('%H:%M')}"
    end

    # "today", "yesterday", "3 days ago", or a date for anything older than 30 days.
    def pf_relative(value)
      return pf_ui('dates.never') if value.nil?

      days = (Time.zone.today - value.to_date).to_i
      return pf_ui('dates.today') if days <= 0
      return pf_ui('dates.yesterday') if days == 1
      return pf_ui('dates.days_ago', count: days) if days < 30

      pf_date(value)
    end

    def pf_hour(hour)
      format('%02d:00', hour.to_i)
    end

    # --- states (Admin::StateLabel: one registry of glyphs and words) -----------

    # A state (Admin::StateLabel::Label): `.word`, `.glyph`, and `.to_s` for
    # both — pf_state(:field_level, :none).word → "Not configured",
    # pf_state(:effective, :blocked).to_s → "⊘ Blocked".
    def pf_state(kind, state)
      PermissionForge::Admin::StateLabel.for(kind, state)
    end

    # The glyph (hidden from assistive technology) and the word of a state
    # (pf_state), for a cell (`<span class="pf-cell__glyph">`) or a legend
    # (`glyph_tag: :b`, one space between) that styles the glyph itself.
    def pf_state_parts(label, glyph_tag: :span, separator: '')
      glyph = content_tag(glyph_tag, label.glyph, class: ('pf-cell__glyph' if glyph_tag == :span), 'aria-hidden': true)
      safe_join([glyph, label.word], separator)
    end

    # Read-only state cell (effective access grid, across-sets lists).
    def pf_state_cell(state, aria:, href: nil, why: nil, current: false)
      state = state.to_sym
      label = pf_state(:effective, state).word
      content = safe_join([content_tag(:span, pf_state(:effective, state).glyph, class: 'pf-cell__glyph', 'aria-hidden': true),
                           content_tag(:span, label)], ' ')
      opts = { class: "pf-state pf-state--#{state}", 'aria-label': "#{aria}: #{label}" }
      opts[:'aria-current'] = 'true' if current
      opts[:data] = { pf_why: why } if why
      href ? link_to(content, href, opts) : content_tag(:span, content, opts)
    end

    # --- banners & footers ----------------------------------------------------

    def pf_help_banner(key, term:, text:)
      return unless pf_help_visible?(key)

      render 'permission_forge/shared/help_banner', key: key, term: term, text: text
    end

    def pf_audit_footer(record, prefix: nil)
      render 'permission_forge/shared/audit_footer', record: record, prefix: prefix
    end

    def pf_tech_details(record, extras: {}, &block)
      render 'permission_forge/shared/tech_details', record: record, extras: extras,
                                                     extra_html: (capture(&block) if block)
    end

    def pf_setting_path(key)
      permission_forge.settings_path(focus: key, anchor: "set-#{key}")
    end

    def pf_setting_link(key, text = nil)
      link_to(text || pf_ui('open_setting'), pf_setting_path(key), class: 'pf-fs-12')
    end

    # Tab link with ARIA state, plus count.
    def pf_tab(label, href, selected:, count: nil)
      text = count.nil? ? label : "#{label} (#{count})"
      link_to(text, href, class: 'pf-tab', role: 'tab', 'aria-selected': selected.to_s)
    end

    def pf_filter_chip(label, href, selected:, count: nil)
      body = [content_tag(:span, label)]
      body << content_tag(:span, count, class: 'pf-filter__count') unless count.nil?
      link_to(safe_join(body), href, class: 'pf-filter', 'aria-current': (selected ? 'true' : nil))
    end

    # A section heading inside a drawer or confirmation page. The page's own title is the h1 when
    # the page stands alone and an h2 inside the dialog (the page behind has the h1), so a section
    # is one level below that.
    def pf_section_heading(text, id: nil)
      content_tag(pf_fragment? ? :h3 : :h2, text, class: 'pf-h3', id: id)
    end

    # A frame that scrolls sideways when its content (a wide grid) is wider than the page: a
    # tab stop with a name (aria-label, or aria-labelledby on a section), so the keyboard
    # reaches the region and assistive technology says what scrolls; the stylesheet paints the
    # cue at its edges and clips what it contains. Every grid 480px or wider goes in one
    # (html/layout_lint_test.rb).
    #   <%= pf_scroll_frame('aria-label': t('.label'), class: 'pf-card') do %> … <% end %>
    #   <%= pf_scroll_frame(tag: :section, 'aria-labelledby': 'pf-changes', class: 'pf-card') do %> … <% end %>
    def pf_scroll_frame(tag: :div, **options, &)
      classes = ['pf-scroll-x', options.delete(:class)].compact.join(' ')
      content_tag(tag, class: classes, role: (tag == :section ? nil : 'region'), tabindex: '0', **options, &)
    end

    # Breadcrumb from [[label, path], ..., label]
    def pf_breadcrumb(*items)
      parts = items.map do |item|
        item.is_a?(Array) ? link_to(item.first, item.last) : content_tag(:span, item, 'aria-current': 'page')
      end
      content_tag(:nav, safe_join(parts, content_tag(:span, '/', 'aria-hidden': true)),
                  class: 'pf-breadcrumb', 'aria-label': pf_ui('breadcrumb'))
    end

    # Re-emits nested params as hidden inputs (the review step re-posts the
    # exact edits that were reviewed).
    def pf_hidden_params(prefix, value)
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      case value
      when Hash
        safe_join(value.map { |k, v| pf_hidden_params("#{prefix}[#{k}]", v) })
      when Array
        safe_join(value.map { |v| pf_hidden_params("#{prefix}[]", v) })
      when nil then safe_join([])
      else
        tag.input(type: 'hidden', name: prefix, value: value.to_s)
      end
    end

    # Drawer / dialog frames. The body is captured here (not via `render
    # layout:`) so lazy t('.key') lookups inside it resolve against the
    # calling view, not the frame partial.
    def pf_sheet_frame(locals = {}, &)
      render 'permission_forge/shared/sheet_frame', **locals, body: capture(&)
    end

    def pf_dialog_frame(locals = {}, &)
      render 'permission_forge/shared/dialog_frame', **locals, body: capture(&)
    end

    # Modal/drawer link: real page without JS, loaded into <dialog> with JS.
    def pf_modal_link(text = nil, href = nil, kind: 'dialog', **opts, &block)
      if block
        opts = (href.is_a?(Hash) ? href : {}).merge(opts)
        href = text
        text = capture(&block)
      end
      opts[:data] = (opts[:data] || {}).merge(pf_modal: kind)
      link_to(text, href, opts)
    end
  end
end
