require 'ipaddr'

module PermissionForge
  module Services
    # Evaluates activation conditions on a permission set against a request context.
    # Returns true if the set is active for the given context (all conditions pass).
    # A nil/blank condition always passes (unconditional).
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

      # Whether a condition of the set cannot be judged in `context`: it
      # restricts the IP and the context has none, or it requires a session
      # flag and the context says nothing about flags (no :session_flags at
      # all — an empty list is an answer). The hours are always judged (the
      # time defaults to now). Under config.conditional_sets_strict_mode a
      # conditional muting set applies then (ConditionalSets#passing).
      #
      # @return [Boolean]
      def self.unjudgeable?(permission_set:, context:)
        context ||= {}
        (permission_set.allowed_ips.present? && context[:ip].blank?) ||
          (permission_set.requires_session_flag.present? && context[:session_flags].nil?)
      end

      def initialize(permission_set, context)
        @permission_set = permission_set
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
      # fails the condition.
      def ip_passes?
        allowed = @permission_set.allowed_ips
        return true if allowed.blank?

        request_ip = @context[:ip]
        return false if request_ip.blank?

        address = request_ip.is_a?(IPAddr) ? request_ip : IPAddr.new(request_ip.to_s)
        parse_ip_ranges(allowed).any? { |range| range.include?(address) }
      rescue IPAddr::Error
        false
      end

      # Login hours: set only active during allowed hour window.
      def hours_pass?
        start_hour = @permission_set.allowed_hours_start
        end_hour = @permission_set.allowed_hours_end
        return true if start_hour.nil? || end_hour.nil?

        hour_in_range?((@context[:time] || Time.current).hour, start_hour, end_hour)
      end

      def hour_in_range?(hour, start_hour, end_hour)
        if start_hour <= end_hour
          hour >= start_hour && hour < end_hour
        else
          # Wraps midnight (e.g., 22-06 means 22:00 to 05:59)
          hour >= start_hour || hour < end_hour
        end
      end

      def parse_ip_ranges(allowed_ips)
        allowed_ips.split(',').filter_map do |cidr|
          IPAddr.new(cidr.strip)
        rescue IPAddr::Error
          nil
        end
      end
    end
  end
end
