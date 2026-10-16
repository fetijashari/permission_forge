module PermissionForge
  # Plain-language sentences for a Permission Set's activation conditions,
  # read through ActivationConditions — the definition that judges them
  # (round 7, E#32 / B#48a): the summary ("Only works from … between …"),
  # its form on the set's own Conditions tab (`here:`), the stored IP
  # entries marked as host data (`markup:`), the problems the validations
  # refuse (#pf_condition_problem) and what such a condition does
  # (#pf_condition_effect, shared with Home's card).
  #
  # @api private
  module ConditionsHelper
    # `here`: the sentence is drawn on the set's own Conditions tab, so a
    # broken condition is not sent "to the Conditions tab" (E#32).
    # `markup`: the stored IP entries in <code> (host data, marked); plain
    # text for an attribute (a title).
    def pf_condition_parts(permission_set, here: false, markup: false)
      [pf_condition_ips(permission_set, here: here, markup: markup), pf_condition_hours(permission_set, here: here),
       pf_condition_flag(permission_set)].compact
    end

    # The IP entries as the engine reads them (ActivationConditions); a list
    # it cannot judge (an entry that is no address, no entry at all) says so
    # (B#48a), never reads as a list of addresses.
    def pf_condition_ips(permission_set, here: false, markup: false)
      conditions = PermissionForge::ActivationConditions.of(permission_set)
      return if conditions.allowed_ip_list.empty? && !conditions.ip_list_broken?

      key = if conditions.ip_list_broken? then here ? 'conditions.ips_broken_here' : 'conditions.ips_broken'
            else 'conditions.from_ips'
            end
      listed = pf_condition_ip_list(conditions, permission_set, markup)
      markup ? pf_t_markup(ips: listed) { |held| pf_ui(key, **held) } : pf_ui(key, ips: listed)
    end

    # The entries as one list ("10.0.0.0/8 or office-network"), each in
    # <code> with `markup`; without it (an attribute, which cannot mark host
    # data) the stored text as written; a list of separators alone as written.
    def pf_condition_ip_list(conditions, permission_set, markup)
      return permission_set.allowed_ips.to_s.strip unless markup

      ips = conditions.allowed_ip_list.presence || [permission_set.allowed_ips.to_s.strip]
      pf_condition_code_list(ips.map { |ip| content_tag(:code, ip, class: 'pf-mono-key') })
    end

    # "a, b or c" from markup, with the page's connectors.
    def pf_condition_code_list(codes)
      return codes.first if codes.one?

      words = PermissionForge::Admin::ListSentence.connectors[:words_connector]
      safe_join([safe_join(codes[0..-2], words), codes.last], pf_ui('conditions.or'))
    end

    # The hour window as the engine reads it: none, a window, an overnight
    # one, or a broken one (one hour of the two, the same hour twice, an
    # hour outside 0–23) that nobody can judge — said so, never shown as an
    # overnight window.
    def pf_condition_hours(permission_set, here: false)
      window = PermissionForge::ActivationConditions.of(permission_set).hours_window
      return unless window.set?

      hours = { from: pf_hour_or_blank(window.from), to: pf_hour_or_blank(window.to) }
      return pf_ui(here ? 'conditions.hours_broken_here' : 'conditions.hours_broken', **hours) if window.broken?

      pf_ui("conditions.#{window.wraps? ? 'hours_overnight' : 'hours'}", **hours)
    end

    def pf_hour_or_blank(hour)
      hour.nil? ? pf_ui('conditions.no_hour') : pf_hour(hour)
    end

    # One sentence per ActivationConditions#condition_problems entry: what
    # cannot be judged, the stored entry as written (in <code>).
    def pf_condition_problem(kind, value)
      case kind
      when :ip_entry then pf_ui('conditions.problems.ip_entry_html', entry: content_tag(:code, value, class: 'pf-mono-key'))
      when :flag_unusable then pf_ui('conditions.problems.flag_unusable_html', flag: content_tag(:code, value.inspect, class: 'pf-mono-key'))
      else pf_ui("conditions.problems.#{kind}")
      end
    end

    # What a condition nobody can judge does to the set (ActivationConditions,
    # ConditionalSets::Member): a granting set never passes, a muting set
    # applies to every request — the words Home's card uses.
    def pf_condition_effect(permission_set)
      pf_ui("conditions.effect.#{permission_set.is_muting ? 'muting' : 'granting'}")
    end

    def pf_condition_flag(permission_set)
      flag = permission_set.requires_session_flag
      pf_flag_phrase(flag) if flag.present?
    end

    # The set's conditions as one sentence; `markup` draws the stored IP
    # entries in <code> (a page's text), without it plain text (a title).
    def pf_condition_sentence(permission_set, here: false, markup: false)
      parts = pf_condition_parts(permission_set, here: here, markup: markup)
      return pf_ui('conditions.always') if parts.empty?
      return pf_ui('conditions.only_works', parts: parts.join(', ')) unless markup

      pf_t_markup(parts: safe_join(parts, ', ')) { |held| pf_ui('conditions.only_works', **held) }
    end

    # The entries of an IP list as written (ActivationConditions.entries).
    def pf_ip_list(value)
      PermissionForge::ActivationConditions.entries(value)
    end

    def pf_flag_label(flag)
      configured = PermissionForge.configuration.admin_session_flags || {}
      configured[flag.to_s] || configured[flag.to_sym] ||
        t("permission_forge.ui.flags.#{flag}", default: flag.to_s)
    end

    def pf_flag_phrase(flag)
      t("permission_forge.ui.conditions.flags.#{flag}",
        default: pf_ui('conditions.flag_generic', flag: pf_flag_label(flag)))
    end
  end
end
