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

    # The time params[key] names, nil when it is blank.
    #
    # @raise [ActionController::BadRequest] for a value that is no time:
    #   a date that cannot be read must never become "no end date"
    def pf_time_param(key)
      value = params[key]
      return nil if value.blank?

      time = Time.zone.parse(value.to_s) if value.is_a?(String)
      time || raise(ActionController::BadRequest, "#{key} is not a time")
    rescue ArgumentError
      raise ActionController::BadRequest, "#{key} is not a time"
    end
  end
end
