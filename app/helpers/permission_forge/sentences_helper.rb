module PermissionForge
  # Plain-language sentences for activation conditions and record rules
  # (audit events: AuditSentencesHelper; "Review and save" change
  # descriptions: ChangesHelper).
  #
  # @api private
  module SentencesHelper
    NULLABLE_OPERATORS = %w[equal not_equal in not_in].freeze
    LIST_OPERATORS = %w[in not_in].freeze
    NO_VALUE_OPERATORS = %w[is_null is_not_null].freeze
    USER_OPERATORS = %w[equal not_equal in not_in is_null is_not_null].freeze
    CURRENT_USER = 'current_user'.freeze
    # Resource flags a Muting Permission Set can take away, in the order the page shows them.
    MUTED_FLAGS = %i[read_access create_access edit_access delete_access].freeze

    # --- activation conditions ------------------------------------------------

    def pf_condition_parts(permission_set)
      [pf_condition_ips(permission_set), pf_condition_hours(permission_set), pf_condition_flag(permission_set)].compact
    end

    # The IP entries as the engine reads them (ActivationConditions).
    def pf_condition_ips(permission_set)
      ips = PermissionForge::ActivationConditions.of(permission_set).allowed_ip_list
      return if ips.empty?

      connector = pf_ui('conditions.or')
      pf_ui('conditions.from_ips', ips: pf_to_sentence(ips, two_words_connector: connector, last_word_connector: connector))
    end

    # The hour window as the engine reads it: none, a window, an overnight
    # one, or a broken one (one hour of the two, the same hour twice, an
    # hour outside 0–23) that nobody can judge — said so, never shown as an
    # overnight window.
    def pf_condition_hours(permission_set)
      window = PermissionForge::ActivationConditions.of(permission_set).hours_window
      return unless window.set?

      hours = { from: pf_hour_or_blank(window.from), to: pf_hour_or_blank(window.to) }
      return pf_ui('conditions.hours_broken', **hours) if window.broken?

      pf_ui("conditions.#{window.wraps? ? 'hours_overnight' : 'hours'}", **hours)
    end

    def pf_hour_or_blank(hour)
      hour.nil? ? pf_ui('conditions.no_hour') : pf_hour(hour)
    end

    def pf_condition_flag(permission_set)
      flag = permission_set.requires_session_flag
      pf_flag_phrase(flag) if flag.present?
    end

    def pf_condition_sentence(permission_set)
      parts = pf_condition_parts(permission_set)
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
    def pf_field_source_sentence(source)
      pf_ui("level_sentences.#{source.level}", set: source.permission_set.name,
                                               strategy: pf_mask_strategy_label(source.mask_strategy))
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

    def pf_rule_value_text(rule)
      value = rule.field_value.to_s
      return '…' if value.strip.empty? # builder preview before a value is entered
      return pf_ui('rules.current_user') if value == CURRENT_USER

      pf_rule_value_parts(rule.operator, value)
    end

    # List values as "a, b"; ranges as "a and b"; anything else verbatim.
    def pf_rule_value_parts(operator, value)
      return value.split(',').map(&:strip).join(', ') if LIST_OPERATORS.include?(operator)
      return value.split(',', 2).map(&:strip).join(" #{pf_ui('rules.and')} ") if operator == 'between'

      value
    end

    def pf_rule_nullable?(rule)
      rule.include_nulls && NULLABLE_OPERATORS.include?(rule.operator)
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
      return if NO_VALUE_OPERATORS.include?(rule.operator)

      content_tag(:span, pf_rule_value_text(rule), class: 'pf-token pf-token--value')
    end

    def pf_rule_text(rule, model_name = rule.resource&.name)
      problem = pf_rule_problem(rule)
      return pf_rule_problem_line(problem) if problem

      field = pf_rule_field_labels(model_name, rule).join(' › ')
      text = "#{pf_ui('rules.only_show')} #{pf_resource_plural(model_name)} #{pf_ui('rules.where')} #{field} " \
             "#{pf_operator_label(rule.operator)}"
      text += " #{pf_rule_value_text(rule)}" unless NO_VALUE_OPERATORS.include?(rule.operator)
      text += ", #{pf_ui('rules.or_empty', field: field)}" if pf_rule_nullable?(rule)
      text
    end

    # Short form used in matrix cells: "Owner is the current user".
    def pf_rule_summary(rule, model_name = rule.resource&.name)
      problem = pf_rule_problem(rule)
      return safe_join(['⊘ ', pf_rule_problem_line(problem)]) if problem

      field = pf_rule_field_labels(model_name, rule).join(' › ')
      value = NO_VALUE_OPERATORS.include?(rule.operator) ? nil : pf_rule_value_text(rule)
      [field, pf_operator_label(rule.operator), value].compact.join(' ')
    end
  end
end
