# frozen_string_literal: true

module PermissionForge
  # The virtual (non-column) fields of one model: names the host declared
  # through extra_fields_method, plus discovered ones while
  # config.virtual_field_discovery is on.
  #
  # The one place extra_fields_method is read. The engine reads it through
  # VirtualFields.extra_names, which raises what the host method raises: a
  # broken method must not silently change permissions. Read models, audits
  # and reader wrapping go through #extra, which logs the error and carries on
  # with no declared names.
  #
  # @example
  #   PermissionForge::VirtualFields.extra_names(Customer) # => ["full_address"]
  #
  #   fields = PermissionForge::VirtualFields.new(Customer)
  #   fields.names                           # => ["full_address", "nickname"]
  #   fields.implicit_grant?('full_address') # => true under extra_fields_default_access = :grant
  #   fields.implicit_grant?('nickname')     # => false: discovered, never granted
  #
  # @api public
  class VirtualFields
    # Names the model declares through extra_fields_method, as Strings and
    # exactly as declared (they may include column names). Empty for a class
    # without the method, and for nil.
    #
    # @raise whatever the host's method raises
    # @return [Array<String>]
    def self.extra_names(klass, configuration = PermissionForge.configuration)
      method = configuration.extra_fields_method
      method && klass.respond_to?(method) ? Array(klass.public_send(method)).map(&:to_s) : []
    end

    # The error the host's method raised when #extra read it, nil otherwise.
    attr_reader :extra_error

    def initialize(klass, configuration = PermissionForge.configuration)
      @klass = klass
      @configuration = configuration
    end

    # VirtualFields.extra_names, except that an error is logged and gives [].
    def extra
      @extra ||= self.class.extra_names(@klass, @configuration)
    rescue StandardError => e
      @extra = extra_unreadable(e)
    end

    # Declared names that are neither a column nor an ignored field.
    def declared
      @declared ||= extra - excluded
    end

    # Listed only while discovery is on; never implicitly granted.
    def discovered
      @discovered ||= @configuration.virtual_field_discovery ? discoverable - excluded - extra : []
    end

    # @return [Array<String>] the declared and discovered virtual field names
    def names
      @names ||= (declared + discovered).uniq
    end

    # Names that get the implicit read + edit entry from ExtraFieldDefaults
    # when no active ResourceField row configures them: every declared name
    # under extra_fields_default_access = :grant, none otherwise.
    def implicit
      @configuration.grant_extra_fields_by_default? ? extra : []
    end

    def implicit_grant?(name)
      implicit.include?(name.to_s)
    end

    # Whether the model has `name` as a virtual field, listed or not (a
    # field configured while discovery was on stays a virtual field).
    def include?(name)
      name = name.to_s
      @klass.column_names.exclude?(name) && (extra.include?(name) || discoverable.include?(name))
    end

    private

    def discoverable
      @discoverable ||= Discovery.call(@klass)
    end

    def excluded
      @klass.column_names + Array(@configuration.ignored_fields).map(&:to_s)
    end

    # Keeps the error for callers that must say what it costs them (reader
    # wrapping), logs it, and gives the empty list #extra then returns.
    def extra_unreadable(error)
      @extra_error = error
      Rails.logger&.warn("[PermissionForge] #{@klass}.#{@configuration.extra_fields_method} raised " \
                         "#{error.class}: #{error.message}. Carrying on as if the model declared no virtual fields.")
      []
    end
  end
end
