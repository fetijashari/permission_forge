# frozen_string_literal: true

module PermissionForge
  module Audit
    # Turns filter parameters (the API endpoint, the HTML audit log) into a
    # relation of audit events. Knows nothing of controllers.
    # Every value reaches the database as a bound value through `where`
    # (never interpolated); a value that is not a plain string, a timestamp
    # that is not ISO 8601, or a name that is not in the catalogue is an
    # error naming the parameter, not a silently empty result.
    #
    # @api private
    class EventQuery
      class Invalid < StandardError
        attr_reader :errors

        # @param errors [Hash{Symbol => Array<String>}] parameter => messages
        def initialize(errors)
          @errors = errors
          super(errors.inspect)
        end
      end

      DATE_ONLY = /\A(\d{4})-(\d{2})-(\d{2})\z/
      TIMESTAMP = /\A(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(\.\d{1,9})?)?(Z|[+-]\d{2}(?::?\d{2})?)?\z/

      # @param params [ActionController::Parameters, Hash] from to event category actor_type actor_id
      #   subject_user_id permission_set record_type record_id correlation_id (others are ignored)
      # @param scope [ActiveRecord::Relation] the events visible to the caller
      # @return [ActiveRecord::Relation] newest first
      # @raise [Invalid] with #errors, parameter => messages
      def self.call(params, scope: PermissionForge::AuditEvent.all)
        new(params, scope).call
      end

      def initialize(params, scope)
        @params = params
        @scope = scope
        @errors = Hash.new { |hash, key| hash[key] = [] }
      end

      # @return [ActiveRecord::Relation] newest first
      # @raise [Invalid]
      def call
        filter_times
        filter_events
        filter_inclusion(:category, PermissionForge::AuditEvent::CATEGORIES)
        filter_inclusion(:actor_type, PermissionForge::AuditEvent::ACTOR_TYPES)
        %i[actor_id subject_user_id correlation_id record_type].each { |name| filter_equal(name) }
        filter_permission_set
        filter_record
        raise Invalid, @errors.to_h if @errors.any?

        @scope.newest_first
      end

      private

      def invalid(name)
        problem(name, :invalid)
      end

      # Rails' own validation messages (errors.messages.<kind>), like the
      # 422 bodies of the other endpoints.
      def problem(name, kind)
        @errors[name] << I18n.t("errors.messages.#{kind}")
      end

      # A parameter's value as a String, nil when absent; an array or hash
      # (`?actor_id[]=1`, `?actor_id[a]=1`) is invalid.
      def value(name)
        raw = @params[name]
        return nil if raw.nil? || raw == ''
        return raw if plain?(raw)

        invalid(name)
        nil
      end

      def plain?(raw)
        raw.is_a?(String) && !raw.include?("\0")
      end

      def filter_equal(name)
        found = value(name)
        @scope = @scope.where(name => found) if found
      end

      def filter_inclusion(name, allowed)
        found = value(name)
        return unless found

        allowed.include?(found) ? @scope = @scope.where(name => found) : invalid(name)
      end

      def filter_events
        raw = @params[:event]
        return if raw.nil? || raw == ''

        names = event_names(raw)
        return invalid(:event) unless names&.all? { |name| PermissionForge::Audit::EventCatalog.registered?(name) }

        @scope = @scope.where(event: names.uniq)
      end

      # nil when anything in the list is not a plain, non-blank string.
      def event_names(raw)
        items = Array.wrap(raw)
        return nil unless items.all? { |item| plain?(item) }

        names = items.flat_map { |item| item.split(',').map(&:strip) }
        names.any?(&:blank?) ? nil : names
      end

      def filter_times
        from = parse_time(:from, end_of_day: false)
        to = parse_time(:to, end_of_day: true)
        @scope = @scope.where(PermissionForge::AuditEvent.arel_table[:occurred_at].gteq(from)) if from
        @scope = @scope.where(PermissionForge::AuditEvent.arel_table[:occurred_at].lteq(to)) if to
      end

      # ISO 8601, read in UTC unless the text carries an offset; an impossible
      # calendar date or clock time is invalid (never rolled over).
      def parse_time(name, end_of_day:)
        text = value(name)
        return nil unless text

        time = DATE_ONLY.match(text) ? parse_day(text, end_of_day) : parse_timestamp(text)
        invalid(name) unless time
        time
      end

      def parse_day(text, end_of_day)
        year, month, day = text.scan(/\d+/).map(&:to_i)
        return nil unless year.positive? && Date.valid_date?(year, month, day)

        moment = Time.utc(year, month, day)
        end_of_day ? moment.end_of_day : moment
      end

      def parse_timestamp(text)
        match = TIMESTAMP.match(text)
        offset = match && utc_offset(match[8])
        return nil unless offset

        year, month, day, hour, minute = match.captures.first(5).map(&:to_i)
        second = Rational("#{match[6] || 0}#{match[7]}")
        return nil unless real_moment?([year, month, day], hour, minute, second)

        Time.new(year, month, day, hour, minute, second, offset)
      end

      def real_moment?(date, hour, minute, second)
        date.first.positive? && Date.valid_date?(*date) && hour < 24 && minute < 60 && second < 60
      end

      # "UTC" for Z or no offset; "+HH:MM" otherwise; nil when out of range.
      def utc_offset(text)
        return 'UTC' if text.nil? || text == 'Z'

        sign, hours, minutes = text.match(/([+-])(\d{2}):?(\d{2})?/).captures
        return nil unless hours.to_i < 24 && minutes.to_i < 60

        format('%<sign>s%<hours>s:%<minutes>s', sign: sign, hours: hours, minutes: minutes || '00')
      end

      # A numeric value is the id, anything else the uuid: one indexed column each.
      def filter_permission_set
        found = value(:permission_set)
        return unless found

        @scope = if found.match?(/\A\d{1,18}\z/)
                   @scope.where(permission_set_id: found.to_i)
                 else
                   @scope.where(permission_set_uuid: found)
                 end
      end

      # record_type alone, or with record_id or record_uuid (each one column, so
      # (record_type, record_id, occurred_at) serves the first). Either id needs
      # record_type.
      def filter_record
        ids = { record_id: value(:record_id), record_uuid: value(:record_uuid) }.compact
        return if ids.empty?

        return problem(:record_type, :blank) if @params[:record_type].blank?

        @scope = @scope.where(ids)
      end
    end
  end
end
