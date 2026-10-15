module PermissionForge
  # Request parameters in the shape an action expects. A crafted request
  # that sends a String or an Array where a Hash is expected, or a Hash where
  # an id or a date is, gets a 4xx (or the value is ignored) — never a 500.
  #
  # Every attribute hash the admin and the API write from (pf_require_hash,
  # pf_hash_param) and every typed text (pf_text_param) comes without NUL
  # bytes: PostgreSQL refuses one in text (a 500), the other databases would
  # store it. The one place for both surfaces; `reason` keeps its own
  # cleaning (Audit::ColumnValues).
  #
  # @api private
  module ParamShapes
    # Typed text: see #pf_text_param.
    #
    # @return [String]
    def self.text(value)
      value.is_a?(String) ? value.delete("\0").strip : ''
    end

    # A request value that cannot be read, naming the parameter: a 400 in
    # the admin, a 422 in the API keyed by the parameter like a validation
    # error (`{ "expires_at": ["is not an ISO 8601 date or time"] }`).
    #
    # @api private
    class InvalidParam < ActionController::BadRequest
      # @return [String] the parameter, e.g. "expires_at"
      attr_reader :param
      # @return [String] what is wrong with it, without its name
      attr_reader :detail

      def initialize(param, detail)
        @param = param.to_s
        @detail = detail
        super("#{@param} #{detail}")
      end
    end

    # The time an ISO 8601 String names, in Time.zone: see IsoTime.
    #
    # @return [ActiveSupport::TimeWithZone, nil] nil for anything else
    def self.time(value) = IsoTime.parse(value)

    # `value` with NUL bytes removed from every String in it, however deep.
    #
    # @return [Object] a new Parameters / Array, or the value itself
    def self.without_nul(value)
      case value
      when String then value.delete("\0")
      when Array then value.map { |item| without_nul(item) }
      when ActionController::Parameters then value.transform_values { |item| without_nul(item) }
      else value
      end
    end

    private

    # params.require(key), which must be a Hash of attributes.
    #
    # @raise [ActionController::ParameterMissing] when it is missing, empty or
    #   not a Hash (400; the API answers 422)
    def pf_require_hash(key)
      value = params.require(key)
      raise ActionController::ParameterMissing, key unless value.is_a?(ActionController::Parameters)

      ParamShapes.without_nul(value)
    end

    # params[key] when it is a Hash of attributes (without NUL bytes), else
    # an empty one.
    def pf_hash_param(key)
      value = params[key]
      value.is_a?(ActionController::Parameters) ? ParamShapes.without_nul(value) : ActionController::Parameters.new
    end

    # Typed text from params[key]: a String without NUL bytes (they cut a
    # quoted SQL literal short, and PostgreSQL refuses them in text) and
    # without surrounding white space; '' for anything else.
    def pf_text_param(key)
      ParamShapes.text(params[key])
    end

    # params[:tab] when it is one of `tabs`, else nil (a Hash or an Array
    # would reach url_for as unpermitted parameters).
    def pf_tab_param(tabs)
      tab = params[:tab]
      tab if tabs.include?(tab)
    end

    # The Integer ids in params[key] (one value or a list); anything that is
    # not digits is dropped.
    def pf_id_list(key)
      Array.wrap(params[key]).filter_map { |value| PermissionForge::Admin::RecordId.cast(value) }
    end

    # The time params[key] names (an ISO 8601 date or date-time, IsoTime),
    # nil when it is blank.
    #
    # @raise [InvalidParam] for anything else ("tuesday", "2026-13-45"): a
    #   date that cannot be read must never become "no end date", nor a time
    #   somebody did not mean
    def pf_time_param(key)
      value = params[key]
      return nil if value.blank?

      ParamShapes.time(value) || raise(InvalidParam.new(key, I18n.t('permission_forge.api.errors.not_iso8601_time')))
    end

    # The ISO 8601 forms a time parameter is read in, and nothing else
    # (Time.zone.parse reads "tuesday" as today 00:00):
    #
    # - a date, `2026-10-22`: the end of that day in Time.zone
    #   (23:59:59.999999999), as the admin's end-date presets: an assignment
    #   that ends on a date lasts through it;
    # - a date and a time of day, `2026-10-22T10:00`, with optional seconds
    #   and fraction (`10:00:00`, `10:00:00.5`), `T` or one space between
    #   them, and an optional offset, `Z` or `+02:00`; without one the time
    #   is read in Time.zone.
    #
    # Every field must exist on the calendar and the clock (no 2026-02-30,
    # no 24:00, no leap second).
    #
    # @api private
    module IsoTime
      FORMAT = /\A(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})
                (?:[T\x20](?<hour>\d{2}):(?<minute>\d{2})(?::(?<second>\d{2})(?:\.(?<fraction>\d{1,9}))?)?
                   (?<offset>Z|[+-]\d{2}:\d{2})?)?\z/x

      # @return [ActiveSupport::TimeWithZone, nil] nil for a value that is not
      #   one of the forms above
      def self.parse(value)
        match = FORMAT.match(value.strip) if value.is_a?(String)
        fields = match && fields_of(match)
        offset = match && match[:offset]
        return unless fields && valid_offset?(offset)

        match[:hour] ? at(fields, offset) : Time.zone.local(*fields.first(3)).end_of_day
      end

      # [year, month, day, hour, minute, seconds with fraction], nil when a
      # field is off the calendar or the clock.
      def self.fields_of(match)
        date = match.values_at(:year, :month, :day).map(&:to_i)
        clock = match.values_at(:hour, :minute, :second).map(&:to_i)
        return unless Date.valid_date?(*date) && valid_clock?(*clock)

        [*date, *clock.first(2), clock.last + fraction_of(match[:fraction])]
      end

      def self.valid_clock?(hour, minute, second)
        hour < 24 && minute < 60 && second < 60
      end

      # nil (no offset) and Z are valid; ±HH:MM within a day.
      def self.valid_offset?(offset)
        return true if offset.nil? || offset == 'Z'

        offset[1, 2].to_i < 24 && offset[4, 2].to_i < 60
      end

      def self.fraction_of(digits)
        digits ? Rational(digits.to_i, 10**digits.size) : 0
      end

      def self.at(fields, offset)
        return Time.zone.local(*fields) unless offset

        Time.new(*fields, offset == 'Z' ? '+00:00' : offset).in_time_zone
      end
      private_class_method :fields_of, :valid_clock?, :valid_offset?, :fraction_of, :at
    end
  end
end
