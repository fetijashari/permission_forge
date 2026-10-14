# frozen_string_literal: true

module PermissionForge
  module Audit
    # The one cleaning of every string an event stores in a column of its own
    # — whoever supplied it: a request (reason, a typed Basic username, a
    # request id), the host (a resolver's label, with_audit_actor, a rake
    # ACTOR or REASON) or the gem. Audit::Recorder applies it to every event
    # it builds.
    #
    #   - valid UTF-8 (invalid bytes replaced), so a row is never refused
    #   - one line: tab, newline and the other line breaks become a space;
    #     NUL (PostgreSQL refuses it) and every other C0/C1 control character
    #     (terminal escapes) are removed
    #   - at most LIMIT characters: the columns are varchar(255), and MySQL
    #     in strict mode refuses — not truncates — a longer value, which
    #     would let a client keep its own refusal out of the log
    #
    # `data` (JSON, escaped by the encoder) is left as it is.
    #
    # @api private
    module ColumnValues
      LIMIT = 255
      COLUMNS = %i[event category actor_type actor_id actor_label source record_type record_id record_uuid record_label
                   permission_set_uuid subject_user_id reason request_id ip correlation_id].freeze
      LINE_BREAKS = /[\t\n\v\f\r\u0085  ]/
      CONTROLS = /[\u0000-\u001F\u007F-\u009F]/

      class << self
        # @param row [Hash] the event's attributes
        # @return [Hash] a copy with every String in COLUMNS cleaned
        def clean(row)
          row.to_h { |column, value| [column, COLUMNS.include?(column) ? value(value) : value] }
        end

        # @return [String, Object] a cleaned String; anything else unchanged
        def value(value)
          return value unless value.is_a?(String)

          utf8(value).gsub(LINE_BREAKS, ' ').gsub(CONTROLS, '')[0, LIMIT]
        end

        private

        def utf8(value)
          text = if [Encoding::UTF_8, Encoding::BINARY].include?(value.encoding)
                   value.dup.force_encoding(Encoding::UTF_8)
                 else
                   value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
                 end
          text.scrub
        end
      end
    end
  end
end
