# frozen_string_literal: true

module PermissionForge
  module Admin
    # The choices of a field's mask-strategy select (the field drawer): the
    # strategies this app knows, after the saved one when this app does not
    # know it — a row written past the model, or a custom strategy since
    # removed from config.custom_mask_strategies (Services::MaskValue.known?).
    # The saved name is offered as it is stored, selected, so a save that
    # changes something else never rewrites the strategy (field test round 6:
    # the select showed nothing selected and a label change saved `full`);
    # it masks fully until the admin picks one this app knows.
    #
    # @example
    #   choices = MaskStrategyChoices.new(field)   # field.mask_strategy == 'emial'
    #   choices.unknown?   # => true
    #   choices.names      # => ['emial', 'full', 'email', 'last4', 'first1_last4']
    #   choices.options    # => [['emial', :unknown_strategy], ['full', nil], ...]
    class MaskStrategyChoices
      # @param field [PermissionForge::ResourceField, nil] the saved row, nil for a column with none
      def initialize(field)
        @field = field
      end

      # The saved strategy is none this app knows, and the row masks.
      def unknown?
        !@field.nil? && @field.mask_access == true && !Services::MaskValue.known?(@field.mask_strategy)
      end

      # The names the select offers, the saved unknown one first.
      #
      # @return [Array<String>]
      def names
        known = Services::MaskValue.strategies.keys.map(&:to_s)
        unknown? && @field.mask_strategy.present? ? [@field.mask_strategy] + known : known
      end

      # [name, note] per choice. The note is the key under
      # `resource_fields.show` shown after the label: :unknown_strategy for
      # the saved name this app does not know, :custom for a configured
      # custom strategy, nil for a built-in.
      #
      # @return [Array<Array(String, Symbol, nil)>]
      def options
        names.map { |name| [name, self.class.note(name)] }
      end

      # @param name [String] a strategy name
      # @return [Symbol, nil] :unknown_strategy, :custom or nil (built-in)
      def self.note(name)
        return :unknown_strategy unless Services::MaskValue.known?(name)

        :custom unless Services::MaskValue::BUILT_IN_STRATEGIES.key?(name.to_s)
      end
    end
  end
end
