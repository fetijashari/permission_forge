# frozen_string_literal: true

require 'ipaddr'

module PermissionForge
  # The activation conditions of a Permission Set as its row holds them: the
  # one reading of `allowed_ips` (a list of IP addresses or CIDR ranges
  # written with commas, newlines or spaces between them) and of the hour
  # window (`allowed_hours_start`, `allowed_hours_end`). Included in
  # PermissionSet (the row) and in ConditionalSets::Member (what the cache
  # keeps of a conditional set); anything else that answers the three
  # readers is read through {.of}.
  #
  # Who reads it: Services::PermissionSetConditionEvaluator (every
  # per-request selection), the PermissionSet validations (a new row, or a
  # changed condition, is refused when it cannot be judged — the stored text
  # is normalised to commas), Admin::ConditionsForm, SentencesHelper, the
  # API serializer and the `conditions` security-audit check.
  #
  # A condition nobody can judge — an entry that is not an address, a list
  # of separators alone, one hour of the two, the same hour twice, an hour
  # outside 0..23 — is *broken* (#conditions_broken?): a granting set never
  # passes on it, with or without a request context, and a muting set always
  # applies (ConditionalSets::Member), in every mode. The condition can only be written past the model.
  #
  # @api private
  module ActivationConditions
    # What separates two entries of an IP list.
    SEPARATORS = /[,\s]+/
    # The hours of a day.
    HOURS = (0..23)

    # The hour window of a set: none (#set? false), a window from `from`
    # (inclusive) to `to` (exclusive) that may wrap midnight (#wraps?), or a
    # broken one (#broken?: one hour missing, an hour outside HOURS, or
    # `from == to`) that includes no hour.
    #
    # @api private
    HoursWindow = Data.define(:from, :to) do
      def set? = !(from.nil? && to.nil?)
      def complete? = !from.nil? && !to.nil?
      def in_range? = [from, to].compact.all? { |hour| HOURS.cover?(hour) }
      def broken? = set? && !problem.nil?
      def wraps? = complete? && from > to

      # Why the window cannot be judged: :hours_incomplete, :hours_range,
      # :hours_equal — nil for a window that can be (or none at all).
      #
      # @return [Symbol, nil]
      def problem
        return unless set?
        return :hours_incomplete unless complete?
        return :hours_range unless in_range?

        :hours_equal if from == to
      end

      # @param hour [Integer] 0..23
      # @return [Boolean] whether the window includes the hour; never for a
      #   broken window or none at all
      def include?(hour)
        return false unless set? && !broken?

        wraps? ? hour >= from || hour < to : hour >= from && hour < to
      end
    end

    # The conditions of an object that answers the three readers (a host's
    # own object, a Struct) without including the module.
    #
    # @api private
    Reading = Data.define(:allowed_ips, :allowed_hours_start, :allowed_hours_end) { include ActivationConditions }

    class << self
      # @param object [#allowed_ips, #allowed_hours_start, #allowed_hours_end]
      # @return [ActivationConditions]
      def of(object)
        return object if object.is_a?(ActivationConditions)

        Reading.new(allowed_ips: object.allowed_ips, allowed_hours_start: object.allowed_hours_start,
                    allowed_hours_end: object.allowed_hours_end)
      end

      # The entries of an IP list as written: a String with commas, newlines
      # or spaces between the entries, or an Array of such Strings (the API
      # takes both). Blanks are dropped; the entries are not checked.
      #
      # @param value [String, Array<String>, nil]
      # @return [Array<String>]
      def entries(value)
        Array(value).flat_map { |part| part.to_s.split(SEPARATORS) }.reject(&:empty?)
      end

      # A condition text as a row stores it: nil for text of whitespace
      # alone — any Unicode space, which Ruby reads as blank while SQL's TRIM
      # takes spaces only — so #conditional? and the SQL scopes read it the
      # same. A row stored before keeps its text; SQL reads it as a
      # condition (narrower: the set is selected per request and passes).
      #
      # @param value [String, nil]
      # @return [String, nil]
      def condition_text(value)
        value.is_a?(String) && value.match?(/\A[[:space:]]*\z/) ? nil : value
      end

      # The address of a request, as the IP list is compared with it: an
      # IPv4-mapped IPv6 address (`::ffff:10.0.0.5`, what a dual-stack
      # server reports for an IPv4 client) as the IPv4 address it holds.
      #
      # @param value [String, IPAddr, nil]
      # @return [IPAddr, nil] nil for anything that is not an address
      def request_address(value)
        return if value.blank?

        address = value.is_a?(IPAddr) ? value : IPAddr.new(value.to_s)
        address.ipv4_mapped? ? address.native : address
      rescue IPAddr::Error
        nil
      end

      # @param entry [String]
      # @return [IPAddr, nil] nil for an entry that is not an IP address or a CIDR range
      def ip_range(entry)
        IPAddr.new(entry)
      rescue IPAddr::Error
        nil
      end
    end

    # @return [Array<String>] the entries of `allowed_ips` as written (.entries)
    def allowed_ip_list
      ActivationConditions.entries(allowed_ips)
    end

    # @return [Array<IPAddr>] the ranges of the entries that are addresses
    def allowed_ip_ranges
      allowed_ip_list.filter_map { |entry| ActivationConditions.ip_range(entry) }
    end

    # @return [Array<String>] the entries of `allowed_ips` that are no address
    def invalid_ip_entries
      allowed_ip_list.reject { |entry| ActivationConditions.ip_range(entry) }
    end

    # Whether the IP list cannot be judged: text that holds no entry, or an
    # entry that is not an address. A blank list is no condition.
    #
    # @return [Boolean]
    def ip_list_broken?
      return false if allowed_ips.blank?

      allowed_ip_list.empty? || invalid_ip_entries.any?
    end

    # @return [HoursWindow]
    def hours_window
      HoursWindow.new(from: allowed_hours_start, to: allowed_hours_end)
    end

    # Whether a condition of the row cannot be judged (see the module).
    #
    # @return [Boolean]
    def conditions_broken?
      ip_list_broken? || hours_window.broken?
    end

    # What the validations refuse about the row's conditions, for a stored
    # row too: `[:ip_entry, entry]` per entry that is no address, `[:ip_empty,
    # text]` for a list of separators, and the window's problem with the
    # window (:hours_incomplete, :hours_range, :hours_equal).
    #
    # @return [Array<Array(Symbol, Object)>]
    def condition_problems
      problems = invalid_ip_entries.map { |entry| [:ip_entry, entry] }
      problems << [:ip_empty, allowed_ips] if allowed_ips.present? && allowed_ip_list.empty?
      window = hours_window
      problems << [window.problem, window] if window.problem
      problems
    end
  end
end
