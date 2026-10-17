# frozen_string_literal: true

module PermissionForge
  module Admin
    # Activation conditions form (Conditions tab): turns the posted IP list,
    # hour window and session flag into PermissionSet attributes, collecting
    # per-input errors (:ips => [messages], :hours => message, :flag =>
    # message). What it refuses is what ActivationConditions cannot judge,
    # for the same reason: an entry ActivationConditions.ip_range does not
    # read as an address, a window whose HoursWindow#problem is not nil.
    class ConditionsForm
      # The hours the tab shows before anything is chosen.
      DEFAULT_HOURS = { from: 8, to: 18 }.freeze
      FLAG_FORMAT = /\A[\w.:-]{1,100}\z/

      attr_reader :errors

      # @param params [ActionController::Parameters, Hash]
      def initialize(params)
        @params = params
        @errors = {}
      end

      # Evaluated in order, so errors are keyed :ips, then :hours, then :flag.
      def attributes
        @attributes ||= {
          allowed_ips: ips.join(',').presence,
          allowed_hours_start: hour(:allowed_hours_start),
          allowed_hours_end: hour(:allowed_hours_end),
          requires_session_flag: session_flag
        }.tap { check_hours }
      end

      private

      # The entries as the engine reads them (ActivationConditions.entries:
      # commas, newlines or spaces between them); an entry
      # ActivationConditions.ip_range does not read as an address is refused.
      def ips
        list = PermissionForge::ActivationConditions.entries(@params[:allowed_ips])
        bad = list.each_with_index.reject { |ip, _| PermissionForge::ActivationConditions.ip_range(ip) }
        @errors[:ips] = bad.map { |ip, i| I18n.t('permission_forge.errors.admin.ip', line: i + 1, ip: ip) } if bad.any?
        list
      end

      # A window nobody can judge (HoursWindow#problem: one hour of the two,
      # an hour outside 0–23, the same hour twice) is refused by the model
      # (PermissionSet#hours_window_is_judgeable); said here too, keyed
      # :hours, so the form shows it next to the selects.
      def check_hours
        problem = posted_window.problem
        @errors[:hours] = I18n.t("permission_forge.errors.admin.#{problem}") if problem
      end

      def posted_window
        PermissionForge::ActivationConditions::HoursWindow.new(from: hour(:allowed_hours_start), to: hour(:allowed_hours_end))
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

      # The hour window the Conditions tab shows: the posted hours of a
      # refused form (`form`), else the set's (HoursWindow; the tab asks it
      # whether it is set, wraps midnight or is broken, never compares the
      # hours itself).
      #
      # @param set [PermissionSet]
      # @param form [ConditionsForm, nil]
      # @return [ActivationConditions::HoursWindow]
      def self.window(set, form)
        stored = set.hours_window
        return stored unless form

        PermissionForge::ActivationConditions::HoursWindow.new(from: form.submitted_hour(:allowed_hours_start) || stored.from,
                                                               to: form.submitted_hour(:allowed_hours_end) || stored.to)
      end

      # Whether the tab shows the hour window switched on: as posted, else as stored.
      def self.hours_on?(set, form)
        form ? form.hours_enabled? : set.hours_window.set?
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
    end
  end
end
