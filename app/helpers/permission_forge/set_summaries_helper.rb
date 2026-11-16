# frozen_string_literal: true

module PermissionForge
  # The Permission Sets list's summary of each set and the overview it opens
  # in place (Admin::SetSummaries, Admin::SetOverview): the access profile,
  # the flag counts, the marks of a Resource or family (rules, masked and
  # hidden fields) and the links that open the overview.
  #
  # @api private
  module SetSummariesHelper
    CRUD_FLAGS = %i[read_access create_access edit_access delete_access].freeze
    ALL_FLAGS = (CRUD_FLAGS + %i[view_all modify_all]).freeze
    # A bar is drawn in tenths (no inline style under the admin's CSP).
    BAR_STEPS = 10

    # "◐ Some changes": the set's access profile (StateLabel :access_profile).
    def pf_access_profile(summary)
      label = pf_state(:access_profile, summary.profile)
      content_tag(:span, pf_state_parts(label, glyph_tag: :b, separator: ' '),
                  class: "pf-access-profile pf-access-profile--#{summary.profile}")
    end

    # Read · Create · Edit · Delete: each flag's count over the set's Resources, with a bar.
    def pf_access_counts(summary)
      flags = summary.flags
      cells = CRUD_FLAGS.map { |flag| pf_access_count(flag, flags[flag], summary) }
      content_tag(:span, safe_join(cells), class: 'pf-access-counts')
    end

    def pf_access_count(flag, count, summary)
      total = summary.resources
      words = t('permission_forge.permission_sets.summary.flag_count',
                flag: t("permission_forge.ui.flags_short.#{flag}"), count: count, total: total)
      content_tag(:span, class: 'pf-access-count') do
        safe_join([content_tag(:span, safe_join([pf_flag_initial(flag), ' ', content_tag(:b, count)]), 'aria-hidden': true),
                   content_tag(:span, words, class: 'pf-sr-only'), pf_bar(count, total, muting: summary.muting)])
      end
    end

    # A bar of `count` out of `total`, in tenths; a count above zero shows at least one.
    def pf_bar(count, total, muting: false)
      step = total.positive? ? ((count.to_f / total) * BAR_STEPS).round.clamp(0, BAR_STEPS) : 0
      step = 1 if step.zero? && count.positive?
      fill = content_tag(:span, nil, class: ['pf-bar__fill', "pf-bar__fill--#{step}", ('pf-bar__fill--muting' if muting)].compact)
      content_tag(:span, fill, class: 'pf-bar', 'aria-hidden': true)
    end

    # The letter a flag is drawn with in a flag strip ("R" for Read).
    def pf_flag_initial(flag)
      t("permission_forge.permission_sets.summary.initials.#{flag}")
    end

    # R C E D │ V M: the six flags of one Resource, a lit letter for each one
    # it grants (or, on a muting set, takes away); the words for assistive
    # technology.
    def pf_flag_strip(flags, muting:)
      on = ALL_FLAGS.select { |flag| flags[flag] }
      letters = ALL_FLAGS.map { |flag| pf_flag_letter(flag, on.include?(flag), muting) }
      words = on.map { |flag| t("permission_forge.ui.flags_short.#{flag}") }
      sentence = words.empty? ? t('permission_forge.permission_sets.summary.no_flags') : words.join(', ')
      safe_join([content_tag(:span, safe_join(letters), class: 'pf-flags', 'aria-hidden': true),
                 content_tag(:span, sentence, class: 'pf-sr-only')])
    end

    def pf_flag_letter(flag, lit, muting)
      return content_tag(:span, '·', class: 'pf-flag pf-flag--off') unless lit

      content_tag(:span, pf_flag_initial(flag), class: ['pf-flag', 'pf-flag--on', ('pf-flag--muting' if muting)].compact)
    end

    # The marks of a Resource or a family (`#marks`: { kind => count }):
    # View All, row rules, rules View All bypasses, masked (or force-masked)
    # and hidden fields. Nothing when it carries none.
    def pf_overview_marks(item)
      marks = item.marks.select { |_kind, count| count.positive? }.map { |kind, count| pf_mark(kind, count) }
      content_tag(:span, safe_join(marks, ' '), class: 'pf-marks') if marks.any?
    end

    # A mark: its glyph and count, and its words (shown on hover, read by assistive technology).
    def pf_mark(kind, count)
      text = t("permission_forge.permission_sets.summary.marks.#{kind}", count: count)
      words = t("permission_forge.permission_sets.summary.mark_titles.#{kind}", count: count)
      content_tag(:span, safe_join([content_tag(:span, text, 'aria-hidden': true), content_tag(:span, words, class: 'pf-sr-only')]),
                  class: "pf-mark pf-mark--#{kind.tr('_', '-')}", title: words)
    end

    # A link that opens a set's overview (`route`: `view:`, `only:`): a page of its
    # own, which the list's script loads in place under the set's row
    # (data-pf-expand); `hide:` is the link's text while what it opened is
    # shown; `described: true` names the set the link belongs to (the set's
    # name on the list) for assistive technology. Other options go to link_to.
    def pf_overview_link(set, text, route, **options)
      hide = options.delete(:hide)
      described = options.delete(:described)
      link_to(text, pf_overview_path(set, route), data: pf_overview_data(set, hide),
                                                  'aria-describedby': (pf_set_name_id(set) if described), **options)
    end

    def pf_overview_path(set, route)
      permission_forge.overview_permission_set_path(set, view: route.fetch(:view), only: route[:only].presence)
    end

    # The slot the overview fills, the row it goes under, and the link's text while it is open.
    def pf_overview_data(set, hide)
      { pf_expand: "pf-set-overview-#{set.id}", pf_expand_row: "pf-set-#{set.id}", pf_expand_hide: hide }.compact
    end

    # The id of the set's name on the list (what its overview links are described by).
    def pf_set_name_id(set) = "pf-set-name-#{set.id}"

    # "⛉ 2 row rules" over "on 2 Resources": a count in the Narrowed by column.
    def pf_narrow_text(text, resources)
      safe_join([content_tag(:span, text),
                 content_tag(:span, t('permission_forge.permission_sets.summary.on_resources', count: resources),
                             class: 'pf-fs-12 pf-text-3')])
    end

    # A Resource's label inside its family, without the family's namespace
    # (`Line` under `Invoices`); the whole label as its title.
    def pf_overview_resource_name(entry, family)
      label = pf_resource_label(entry.name)
      prefix = "#{family.name}::"
      short = family.name && label.start_with?(prefix) ? label.delete_prefix(prefix) : label
      content_tag(:code, short, title: (label unless short == label))
    end

    # The Resource's name, linked to its page; a name stored past the
    # validation (blank, or not a constant path: no route carries it) is
    # shown, never linked (a 500 otherwise).
    def pf_overview_resource_link(set, entry, family)
      name = pf_overview_resource_name(entry, family)
      return name unless PermissionForge::RESOURCE_NAME_FORMAT.match?(entry.name)

      link_to(name, permission_forge.permission_set_resource_path(set, entry.name))
    end

    # A family's name: its namespace, or "Other models".
    def pf_family_name(family)
      return t('permission_forge.permission_sets.overview.no_family') if family.name.nil?

      content_tag(:code, family.name, class: 'pf-family__name')
    end
  end
end
