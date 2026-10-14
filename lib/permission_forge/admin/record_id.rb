# frozen_string_literal: true

module PermissionForge
  module Admin
    # The id of a PermissionForge record, from a request value: an Integer, or
    # nil for anything that is not one — blank, a Hash, an Array, text, or more
    # digits than a bigint holds (the database would raise, or read '1abc' as 1).
    module RecordId
      FORMAT = /\A\d{1,18}\z/

      # @param value [Object]
      # @return [Integer, nil]
      def self.cast(value)
        text = value.to_s.strip if value.is_a?(String) || value.is_a?(Integer)
        text.to_i if text&.match?(FORMAT)
      end
    end
  end
end
