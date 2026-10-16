module PermissionForge
  # Plain-language sentences for activation conditions and record rules
  # (audit events: AuditSentencesHelper; "Review and save" change
  # descriptions: ChangesHelper).
  #
  # @api private
  module SentencesHelper
    # Resource flags a Muting Permission Set can take away, in the order the page shows them.
    MUTED_FLAGS = %i[read_access create_access edit_access delete_access].freeze

    # --- activation conditions ------------------------------------------------

    # `here`: the sentence is drawn on the set's own Conditions tab, so a
    # broken condition is not sent "to the Conditions tab" (E#32).
    def pf_condition_parts(permission_set, here: false)
      [pf_condition_ips(permission_set, here: here), pf_condition_hours(permission_set, here: here),
       pf_condition_flag(permission_set)].compact
    end

    # The IP entries as the engine reads them (ActivationConditions); a list
    # it cannot judge (an entry that is no address, no entry at all) says so
    # (B#48a), never reads as a list of addresses.
    def pf_condition_ips(permission_set, here: false)
      conditions = PermissionForge::ActivationConditions.of(permission_set)
      ips = conditions.allowed_ip_list
      return if ips.empty? && !conditions.ip_list_broken?

      connector = pf_ui('conditions.or')
      listed = pf_to_sentence(ips, two_words_connector: connector, last_word_connector: connector)
      return pf_ui('conditions.from_ips', ips: listed) unless conditions.ip_list_broken?

      pf_ui(here ? 'conditions.ips_broken_here' : 'conditions.ips_broken', ips: listed.presence || permission_set.allowed_ips.to_s.strip)
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

    def pf_condition_sentence(permission_set, here: false)
      parts = pf_condition_parts(permission_set, here: here)
      return pf_ui('conditions.always') if parts.empty?

      pf_ui('conditions.only_works', parts: parts.join(', '))
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

    # --- resources ------------------------------------------------------------

    # The toast after "Add resource": how many fields it got. In a Muting
    # Permission Set "with 0 fields" reads like a gap, so there it says what
    # the resource takes away, or that it takes nothing away yet.
    def pf_added_resource_notice(resource, muting:)
      label = pf_resource_label(resource)
      count = resource.resource_fields.size
      return t('permission_forge.flash.resources.added', resource: label, count: count) unless muting

      taken = pf_muted_parts(resource, count)
      return t('permission_forge.flash.resources.added_muting_nothing', resource: label) if taken.empty?

      t('permission_forge.flash.resources.added_muting', resource: label, what: pf_to_sentence(taken))
    end

    # What a muting resource takes away: its muted flags, then its field rows.
    def pf_muted_parts(resource, field_count)
      parts = MUTED_FLAGS.select { |flag| resource.public_send(flag) }.map { |flag| pf_ui("flags_short.#{flag}") }
      parts << t('permission_forge.flash.resources.muted_fields', count: field_count) if field_count.positive?
      parts
    end

    # --- field levels ---------------------------------------------------------

    # What one Permission Set does to a field, by its level (an
    # Admin::EffectiveAccess::FieldSource): "Sales rep shows this field masked (Email)."
    # `set_name`: how the set is named (LabelsHelper#pf_chain_set_name on a
    # person's effective access); the set's name by default.
    def pf_field_source_sentence(source, set_name: pf_record_name(source.permission_set))
      strategy = pf_mask_strategy_label(source.mask_strategy)
      pf_t_markup(set: set_name) { |held| pf_ui("level_sentences.#{source.level}", **held, strategy: strategy) }
    end

    # --- record rules ---------------------------------------------------------

    def pf_operator_label(operator)
      t("permission_forge.ui.operators.#{operator}", default: operator.to_s)
    end

    # Labels along a rule's relationship path and the final field, e.g.
    # ["Organization", "Members", "User"]. The path is walked by
    # Operators::RulePath (the one walk of a path); one it cannot follow is
    # labelled from its names (a rule that matches nothing is drawn by
    # RuleProblemsHelper first).
    def pf_rule_field_labels(model_name, rule)
      segments = PermissionForge::Operators::RuleColumn.path_segments(rule.field_accessor_path)
      models = pf_rule_path_models(PermissionForge::ModelLookup.model_for(model_name), segments)
      labels = segments.each_with_index.map { |assoc, index| pf_attribute_label(models[index], assoc) }
      labels << pf_attribute_label(models[segments.size], rule.field_name)
    end

    # The label of a stored attribute or association name (Admin::FieldLabel),
    # as text: the host's translation, else the name as stored.
    def pf_attribute_label(klass, attribute)
      pf_field_label_text(klass, attribute)
    end

    # The model, then the model of each association on the path; the model
    # alone when the path cannot be followed (or nothing, without a model).
    def pf_rule_path_models(klass, segments)
      return [] unless klass.is_a?(Class) && klass < ActiveRecord::Base

      PermissionForge::Operators::RulePath.follow(klass, segments).models.presence || [klass]
    rescue *PermissionForge::Operators::RuleColumn::UNTELLABLE
      [klass]
    end

    # The value as the rule compares it: "the current user" only where
    # ValueTyping substitutes the user's id (one value compared:
    # ValueTyping.current_user?); in a list the word is an element as written.
    def pf_rule_value_text(rule)
      value = rule.field_value.to_s
      return '…' if value.strip.empty? # builder preview before a value is entered
      return pf_ui('rules.current_user') if PermissionForge::Operators::ValueTyping.current_user?(rule.operator, value)

      pf_rule_value_parts(rule.operator, value)
    end

    # A list's values as "a, b"; a range's ends as "a and b" — split as
    # ValueTyping splits them (its SHAPES: :list, :pair); anything else verbatim.
    def pf_rule_value_parts(operator, value)
      parts = PermissionForge::Operators::ValueTyping.split(value)
      case PermissionForge::Operators::ValueTyping::SHAPES[operator]
      when :list then parts.join(', ')
      when :pair then parts.join(" #{pf_ui('rules.and')} ")
      else value
      end
    end

    # Whether the sentence adds "or … is empty": the rule includes the NULL
    # rows and its operator's strategy adds them (Operators::Registry::NULL_INCLUDING).
    def pf_rule_nullable?(rule)
      rule.include_nulls && PermissionForge::Operators::Registry::NULL_INCLUDING.include?(rule.operator)
    end

    # Whether the operator takes no value (Operators::Validations::VALUELESS: the null checks).
    def pf_rule_valueless?(rule)
      PermissionForge::Operators::Validations.valueless?(rule.operator)
    end

    # Token sentence: Only show [Customers] where [Owner] [is] [the current user], or Owner is empty.
    # A rule that matches nothing says so, and what it names as written.
    def pf_rule_sentence(rule, model_name = rule.resource&.name)
      problem = pf_rule_problem(rule)
      return pf_rule_problem_sentence(rule, problem) if problem

      field = pf_rule_field_labels(model_name, rule).join(' › ')
      sentence = safe_join(pf_rule_tokens(rule, model_name, field), ' ')
      sentence = safe_join([sentence, content_tag(:span, ", #{pf_ui('rules.or_empty', field: field)}")]) if pf_rule_nullable?(rule)
      content_tag(:p, sentence, class: 'pf-sentence')
    end

    def pf_rule_tokens(rule, model_name, field)
      [
        content_tag(:span, pf_ui('rules.only_show')),
        content_tag(:span, pf_resource_plural(model_name), class: 'pf-token'),
        content_tag(:span, pf_ui('rules.where')),
        content_tag(:span, field, class: 'pf-token'),
        content_tag(:span, pf_operator_label(rule.operator), class: 'pf-token'),
        pf_rule_value_token(rule)
      ].compact
    end

    def pf_rule_value_token(rule)
      return if pf_rule_valueless?(rule)

      content_tag(:span, pf_rule_value_text(rule), class: 'pf-token pf-token--value')
    end

    def pf_rule_text(rule, model_name = rule.resource&.name)
      problem = pf_rule_problem(rule)
      return pf_rule_problem_line(problem) if problem

      field = pf_rule_field_labels(model_name, rule).join(' › ')
      text = "#{pf_ui('rules.only_show')} #{pf_resource_plural(model_name)} #{pf_ui('rules.where')} #{field} " \
             "#{pf_operator_label(rule.operator)}"
      text += " #{pf_rule_value_text(rule)}" unless pf_rule_valueless?(rule)
      text += ", #{pf_ui('rules.or_empty', field: field)}" if pf_rule_nullable?(rule)
      text
    end

    # Short form used in matrix cells: "Owner is the current user".
    def pf_rule_summary(rule, model_name = rule.resource&.name)
      problem = pf_rule_problem(rule)
      return safe_join(['⊘ ', pf_rule_problem_line(problem)]) if problem

      field = pf_rule_field_labels(model_name, rule).join(' › ')
      value = pf_rule_valueless?(rule) ? nil : pf_rule_value_text(rule)
      [field, pf_operator_label(rule.operator), value].compact.join(' ')
    end
  end
end
