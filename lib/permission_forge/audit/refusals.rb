# frozen_string_literal: true

module PermissionForge
  module Audit
    # The payloads of refusal events built from what a client sent, bounded:
    # a refused request must not be able to make its own record too big to
    # store (MySQL refuses an over-long value; a huge JSON row costs the
    # store), nor shape it with nested parameters.
    #
    # @api private
    module Refusals
      # How many of the people concerned are listed; user_count has them all.
      USER_IDS_LIMIT = 100
      VALUE_LIMIT = 255

      module_function

      # The payload of a refused change to who holds a Permission Set or
      # belongs to a Permission Set Group, for Audit.record / pf_audit_refused.
      #
      # @param target [PermissionForge::PermissionSet, PermissionForge::PermissionSetGroup, nil]
      # @param user_ids [Object] as the client sent them: a scalar, an Array, anything
      # @param action [Symbol, String, nil] e.g. :grant, :revoke, :add_member
      # @param hook [String] the option that refused (data 'hook')
      # @return [Hash] subject_user_id: (one person only), permission_set: or record:, data:
      def assignment(target, user_ids, hook:, action: nil)
        ids = user_ids_of(user_ids)
        data = { 'reason' => 'assignment_not_authorized', 'hook' => hook,
                 'user_ids' => ids.first(USER_IDS_LIMIT), 'user_count' => ids.size }
        data['action'] = action.to_s if action
        { subject_user_id: (ids.first if ids.one?), data: data, **target_reference(target) }
      end

      # Scalars only (strings, numbers), each as a String of at most
      # VALUE_LIMIT characters; nested arrays are flattened, hashes dropped.
      #
      # @return [Array<String>]
      def user_ids_of(user_ids)
        return [] if user_ids.nil? || user_ids.is_a?(Hash) || user_ids.respond_to?(:to_unsafe_h)

        Array(user_ids).flatten.filter_map { |id| scalar(id) }
      end

      # @return [String, nil] a non-empty String or number, capped
      def scalar(value)
        return unless value.is_a?(String) || value.is_a?(Numeric)

        value.to_s[0, VALUE_LIMIT].presence
      end

      # A Permission Set fills permission_set_id/uuid; a group is the record.
      def target_reference(target)
        case target
        when nil then {}
        when PermissionForge::PermissionSet then { permission_set: target }
        else { record: target }
        end
      end
    end
  end
end
