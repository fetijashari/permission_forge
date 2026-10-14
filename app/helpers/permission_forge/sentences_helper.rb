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

    # --- activation conditions ------------------------------------------------

    def pf_condition_parts(permission_set)
      [pf_condition_ips(permission_set), pf_condition_hours(permission_set), pf_condition_flag(permission_set)].compact
    end

    def pf_condition_ips(permission_set)
      ips = pf_ip_list(permission_set.allowed_ips)
      return if ips.empty?

      connector = pf_ui('conditions.or')
      pf_ui('conditions.from_ips', ips: ips.to_sentence(two_words_connector: connector, last_word_connector: connector))
    end

    def pf_condition_hours(permission_set)
      from = permission_set.allowed_hours_start
      to = permission_set.allowed_hours_end
      return unless from.present? && to.present?

      key = to.to_i <= from.to_i ? 'hours_overnight' : 'hours'
      pf_ui("conditions.#{key}", from: pf_hour(from), to: pf_hour(to))
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

    def pf_ip_list(value)
      value.to_s.split(/[,\n]/).map(&:strip).reject(&:empty?)
    end

    def pf_flag_label(flag)
      configured = PermissionForge.configuration.admin_session_flags || {}
      configured[flag.to_s] || configured[flag.to_sym] ||
        t("permission_forge.ui.flags.#{flag}", default: flag.to_s.humanize)
    end

    def pf_flag_phrase(flag)
      t("permission_forge.ui.conditions.flags.#{flag}",
        default: pf_ui('conditions.flag_generic', flag: pf_flag_label(flag)))
    end

    # --- record rules ---------------------------------------------------------

    def pf_operator_label(operator)
      t("permission_forge.ui.operators.#{operator}", default: operator.to_s.humanize.downcase)
    end

    # Labels along a rule's relationship path and the final field, e.g.
    # ["Organization", "Members", "User"].
    def pf_rule_field_labels(model_name, rule)
      klass = model_name.to_s.safe_constantize
      labels = rule.field_accessor_path.to_s.split('.').map do |assoc|
        label = pf_attribute_label(klass, assoc)
        klass = pf_association_class(klass, assoc)
        label
      end
      labels << pf_attribute_label(klass, rule.field_name)
    end

    def pf_attribute_label(klass, attribute)
      klass ? klass.human_attribute_name(attribute) : attribute.to_s.humanize
    end

    # Target class of an association, or nil (unknown or polymorphic).
    def pf_association_class(klass, assoc)
      reflection = klass&.reflect_on_association(assoc.to_sym)
      begin
        reflection&.klass
      rescue StandardError
        nil
      end
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

    # Plural model label. model_name.human(count: 2) falls back to the singular
    # when the host app has no model translations, so pluralize English then.
    def pf_resource_plural(name)
      klass = name.to_s.safe_constantize
      return name.to_s.demodulize.pluralize unless klass.respond_to?(:model_name)

      plural = klass.model_name.human(count: 2)
      plural == klass.model_name.human && I18n.locale.to_s == 'en' ? plural.pluralize : plural
    end

    def pf_resource_label(resource_or_name)
      name = resource_or_name.respond_to?(:name) ? resource_or_name.name : resource_or_name.to_s
      return resource_or_name.label if resource_or_name.respond_to?(:label) && resource_or_name.label.present?

      klass = name.safe_constantize
      klass.respond_to?(:model_name) ? klass.model_name.human : name.demodulize.titleize
    end

    # Token sentence: Only show [Customers] where [Owner] [is] [the current user], or Owner is empty
    def pf_rule_sentence(rule, model_name = rule.resource&.name)
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
      field = pf_rule_field_labels(model_name, rule).join(' › ')
      text = "#{pf_ui('rules.only_show')} #{pf_resource_plural(model_name)} #{pf_ui('rules.where')} #{field} " \
             "#{pf_operator_label(rule.operator)}"
      text += " #{pf_rule_value_text(rule)}" unless NO_VALUE_OPERATORS.include?(rule.operator)
      text += ", #{pf_ui('rules.or_empty', field: field)}" if pf_rule_nullable?(rule)
      text
    end

    # Short form used in matrix cells: "Owner is the current user".
    def pf_rule_summary(rule, model_name = rule.resource&.name)
      field = pf_rule_field_labels(model_name, rule).join(' › ')
      value = NO_VALUE_OPERATORS.include?(rule.operator) ? nil : pf_rule_value_text(rule)
      [field, pf_operator_label(rule.operator), value].compact.join(' ')
    end
  end
end
