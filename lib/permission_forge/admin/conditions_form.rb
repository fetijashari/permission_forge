# frozen_string_literal: true

require 'ipaddr'

module PermissionForge
  module Admin
    # Activation conditions form (Conditions tab): turns the posted IP list,
    # hour window and session flag into PermissionSet attributes, collecting
    # per-input errors (:ips => [messages], :flag => message).
    class ConditionsForm
      FLAG_FORMAT = /\A[\w.:-]{1,100}\z/

      attr_reader :errors

      # @param params [ActionController::Parameters, Hash]
      def initialize(params)
        @params = params
        @errors = {}
      end

      # Evaluated in order, so errors are keyed :ips before :flag.
      def attributes
        @attributes ||= {
          allowed_ips: ips.join(',').presence,
          allowed_hours_start: hour(:allowed_hours_start),
          allowed_hours_end: hour(:allowed_hours_end),
          requires_session_flag: session_flag
        }
      end

      private

      def ips
        list = @params[:allowed_ips].to_s.split(/[\n,]/).map(&:strip).reject(&:empty?)
        bad = list.each_with_index.reject { |ip, _| valid_ip?(ip) }
        @errors[:ips] = bad.map { |ip, i| I18n.t('permission_forge.errors.admin.ip', line: i + 1, ip: ip) } if bad.any?
        list
      end

      public

      # Whether the hour window was switched on in the posted form.
      def hours_enabled?
        @params[:hours_enabled] == '1'
      end

      # The hour posted for `key` as an Integer, or nil when it is not a
      # number (blank, a Hash, an Array) — what the form shows again.
      def submitted_hour(key)
        RecordId.cast(@params[key])
      end

      private

      # nil unless the hour window is enabled.
      def hour(key)
        submitted_hour(key) if hours_enabled?
      end

      def session_flag
        custom = @params[:requires_session_flag_custom].to_s.strip
        flag = custom.presence || @params[:requires_session_flag].to_s.strip
        return flag.presence if flag.blank? || flag.match?(FLAG_FORMAT)

        @errors[:flag] = I18n.t('permission_forge.errors.admin.flag')
        nil
      end

      # IPAddr::Error is an ArgumentError.
      def valid_ip?(value)
        IPAddr.new(value)
        true
      rescue ArgumentError
        false
      end
    end
  end
end
