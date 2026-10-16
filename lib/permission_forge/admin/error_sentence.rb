# frozen_string_literal: true

module PermissionForge
  module Admin
    # A model's refusals as sentences in the page's language ("Name already
    # exists in this permission set"), from the gem's own keys: Rails'
    # `full_messages` reads `errors.format` and `human_attribute_name`,
    # English in a host without rails-i18n. The attribute is named by
    # `permission_forge.validations.attributes.<attribute>`, else by the
    # attribute's stored name verbatim; the message is the validator's
    # (every validator of the gem's models has a `permission_forge.validations.*` key).
    #
    # @example
    #   ErrorSentence.all(record.errors)   # => ["Name already exists in this permission set"]
    #
    # @api private
    module ErrorSentence
      SCOPE = 'permission_forge.validations'

      # @param errors [ActiveModel::Errors]
      # @return [Array<String>]
      def self.all(errors)
        errors.map { |error| sentence(error.attribute, error.message) }
      end

      # @param errors [ActiveModel::Errors]
      # @return [String, nil]
      def self.first(errors)
        all(errors).first
      end

      # @param attribute [Symbol, String]
      # @param message [String] the validator's message
      # @return [String]
      def self.sentence(attribute, message)
        return message.to_s if attribute.to_s == 'base'

        I18n.t("#{SCOPE}.full_message", attribute: attribute_label(attribute), message: message)
      end

      # @return [String] the attribute's label, else its name as stored
      def self.attribute_label(attribute)
        I18n.t("#{SCOPE}.attributes.#{attribute}", default: attribute.to_s)
      end
    end
  end
end
