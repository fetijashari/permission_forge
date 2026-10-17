# frozen_string_literal: true

module PermissionForge
  module Admin
    # A list as a sentence ("Bob, Carol and Dan") with the connectors of the
    # current locale, read from the gem's own keys
    # (permission_forge.support.array.*): Array#to_sentence reads Rails'
    # support.array keys, which an app without rails-i18n has in English only,
    # so a Macedonian page would read "Bob and Carol". The admin joins every
    # list through here (helper: pf_to_sentence); a test fails on a bare
    # to_sentence in app/ or lib/.
    #
    # @api private
    #
    # @example
    #   ListSentence.call(%w[Bob Carol Dan]) # => "Bob, Carol and Dan" (en)
    module ListSentence
      # @param items [Array<#to_s>]
      # @param overrides [Hash] connectors that replace the locale's (e.g. "or")
      # @return [String]
      def self.call(items, **overrides)
        Array(items).to_sentence(**connectors, **overrides)
      end

      def self.connectors
        { words_connector: I18n.t('permission_forge.support.array.words_connector'),
          two_words_connector: I18n.t('permission_forge.support.array.two_words_connector'),
          last_word_connector: I18n.t('permission_forge.support.array.last_word_connector') }
      end
    end
  end
end
