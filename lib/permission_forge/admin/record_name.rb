# frozen_string_literal: true

module PermissionForge
  module Admin
    # The one definition of the name the admin shows for a Permission Set, a
    # Permission Set Group or a rule: its stored name, except the install
    # migration's English default for its kind ('Untitled Permission Set',
    # 'Untitled Permission Set Group', 'Untitled Rule'; GeneratedText.name?),
    # which an API create without a name stored before 0.15 — that is
    # named in the page's language (`permission_forge.ui.untitled.<kind>`),
    # never shown as if an admin had written English (round 7, S4). Stored
    # data is never rewritten. Views ask through `pf_record_name`; the
    # locale-leak walk stores the defaults on the walked records, so a page
    # that prints one as stored fails it.
    #
    # @example
    #   RecordName.for(set)   # => "Sales rep", or "Grup lejesh pa emër" for a stored 'Untitled Permission Set' on sq
    #
    # @api private
    module RecordName
      # @param record [PermissionSet, PermissionSetGroup, PermissionSetRule, nil]
      # @return [String] the name to show ('' for no record)
      def self.for(record)
        return '' if record.nil?

        text(record.name, record.model_name.element)
      end

      # A stored name of `kind` (a name a list or an event kept, without its
      # record): the same reading as .for.
      #
      # @param name [String, nil]
      # @param kind [Symbol, String, Class] :permission_set, :permission_set_group,
      #   :permission_set_rule, or the model class
      # @return [String]
      def self.text(name, kind)
        name = name.to_s
        return name unless name.strip.empty? || GeneratedText.name?(name, kind)

        element = kind.respond_to?(:model_name) ? kind.model_name.element : kind.to_s
        I18n.t("permission_forge.ui.untitled.#{element}")
      end
    end
  end
end
