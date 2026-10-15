# frozen_string_literal: true

module PermissionForge
  module Services
    class PermitsAttributes
      # What `PermitsAttributes.call(..., report: true)` answers: the filtered
      # params and what was dropped from them.
      #
      # @!attribute [r] params
      #   @return [Hash] the filtered params, as `call` without `report:` returns them
      # @!attribute [r] dropped
      #   @return [Array<String>] the paths of the dropped keys, in order, without
      #     repeats: `status`, `supplier_attributes.secret`,
      #     `lines_attributes.*.price`, `lines_attributes.*` (an element that is
      #     no record, or one whose id the user may not reach); never values
      #
      # @api public
      Result = Data.define(:params, :dropped) do
        # @return [Boolean] whether any key was dropped
        def dropped? = dropped.any?

        # The top-level keys behind the dropped paths (`lines_attributes`
        # for `lines_attributes.*.price`), for a message such as
        # "Not saved: status, notes".
        #
        # @return [Array<String>]
        def dropped_fields = dropped.map { |path| path.split('.', 2).first }.uniq
      end
    end
  end
end
