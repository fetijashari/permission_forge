require 'ipaddr'

module PermissionForge
  module Services
    # Evaluates activation conditions on a permission set against a request context.
    # Returns true if the set is active for the given context (all conditions pass).
    # A nil/blank condition always passes (unconditional).
    #
    # The conditions are read through PermissionForge::ActivationConditions
    # (the one parser of the IP list and the hour window). A condition nobody
    # can judge — an IP entry that is not an address, a list of separators,
    # one hour of the two, the same hour twice, an hour outside 0..23 — never
    # passes (.broken?); ConditionalSets applies a muting set with one.
    #
    # @example
    #   PermissionSetConditionEvaluator.call(
    #     permission_set: ps,
    #     context: { ip: '192.168.1.5', session_flags: ['mfa_verified'], time: Time.current }
    #   )
    #   # => true or false
    #
    # @api public
    class PermissionSetConditionEvaluator
      # @param permission_set [PermissionSet]
      # @param context [Hash] `ip:`, `session_flags:` and `time:` of the request
      # @return [Boolean]
      def self.call(permission_set:, context:)
        new(permission_set, context).call
      end

      # Whether a condition of the set cannot be judged in `context`: the
      # set holds a broken condition (.broken?, whatever the context), it
      # restricts the IP and the context has none, or it requires a session
      # flag and the context says nothing about flags (no :session_flags at
      # all — an empty list is an answer). The hours are always judged (the
      # time defaults to now). A conditional muting set applies then under
      # config.conditional_sets_strict_mode — and with a broken condition in
      # every mode (ConditionalSets::Member#applies?).
      #
      # @return [Boolean]
      def self.unjudgeable?(permission_set:, context:)
        context ||= {}
        broken?(permission_set: permission_set) ||
          (permission_set.allowed_ips.present? && context[:ip].blank?) ||
          (permission_set.requires_session_flag.present? && context[:session_flags].nil?)
      end

      # Whether the set holds a condition nobody can judge
      # (ActivationConditions#conditions_broken?): such a set never passes.
      #
      # @param permission_set [PermissionSet, #allowed_ips]
      # @return [Boolean]
      def self.broken?(permission_set:)
        PermissionForge::ActivationConditions.of(permission_set).conditions_broken?
      end

      def initialize(permission_set, context)
        @permission_set = permission_set
        @conditions = PermissionForge::ActivationConditions.of(permission_set)
        @context = context || {}
      end

      # @return [Boolean] whether every condition of the set passes in the context
      def call
        session_flag_passes? && ip_passes? && hours_pass?
      end

      private

      # Session flag: set only active when context includes the required flag.
      def session_flag_passes?
        flag = @permission_set.requires_session_flag
        return true if flag.blank?

        Array(@context[:session_flags]).include?(flag)
      end

      # IP restriction: set only active when request IP matches allowed CIDRs.
      # The IP may be a String or an IPAddr; anything that is not an address
      # fails the condition, as does a list that cannot be judged.
      def ip_passes?
        return true if @permission_set.allowed_ips.blank?
        return false if @conditions.ip_list_broken?

        request_ip = @context[:ip]
        return false if request_ip.blank?

        address = request_ip.is_a?(IPAddr) ? request_ip : IPAddr.new(request_ip.to_s)
        @conditions.allowed_ip_ranges.any? { |range| range.include?(address) }
      rescue IPAddr::Error
        false
      end

      # Login hours: set only active during the allowed hour window; a
      # broken window (one hour, the same hour twice, out of range) includes
      # no hour.
      def hours_pass?
        window = @conditions.hours_window
        return true unless window.set?

        window.include?((@context[:time] || Time.current).hour)
      end
    end
  end
end
