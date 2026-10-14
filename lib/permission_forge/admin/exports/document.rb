# frozen_string_literal: true

module PermissionForge
  module Admin
    module Exports
      # A file the admin hands over (CSV or JSON): a metadata block — what was
      # exported, when, by whom, with which filters, how many rows — then
      # every row. Rows are produced lazily, one batch at a time, so a large
      # export is written as it is read and nothing is cut off.
      #
      # CSV layout:
      #   export,<kind>
      #   exported_at,<ISO 8601>
      #   exported_by,<label>          (and exported_by_type / exported_by_id)
      #   filters,<JSON>
      #   row_count,<n>
      #   <empty line>
      #   <column names>
      #   <rows>
      #
      # JSON layout: { "meta": {...}, "columns": [...], "data": [ {...}, ... ] }
      class Document
        attr_reader :columns, :meta

        # @param columns [Array<String>] the row keys, in order
        # @param meta [Hash{String => Object}] export, exported_at, exported_by, filters, row_count …
        # @param rows [#call] callable taking a block; yields each row as a Hash{String => Object}
        def initialize(columns:, meta:, rows:)
          @columns = columns
          @meta = meta
          @rows = rows
        end

        # @return [Enumerator<String>] the CSV, chunk by chunk
        def csv
          Enumerator.new do |out|
            out << csv_head
            @rows.call { |row| out << csv_row(row) }
          end
        end

        # The metadata block, an empty line, the column names.
        def csv_head
          Csv.document(meta.map { |key, value| [key, flat(value)] }) + Csv::LINE_END + Csv.line(columns)
        end

        # @return [Enumerator<String>] the JSON, chunk by chunk
        def json
          Enumerator.new do |out|
            out << %({"meta":#{ActiveSupport::JSON.encode(meta)},"columns":#{ActiveSupport::JSON.encode(columns)},"data":[)
            first = true
            @rows.call do |row|
              out << (first ? '' : ',') << ActiveSupport::JSON.encode(row.slice(*columns))
              first = false
            end
            out << "]}\n"
          end
        end

        # @param format [Symbol, String] :csv or :json
        # @return [Enumerator<String>]
        def chunks(format)
          format.to_s == 'json' ? json : csv
        end

        # The whole file as one String (tests, small exports).
        def render(format)
          chunks(format).to_a.join
        end

        private

        # One row as a CSV line, in column order.
        def csv_row(row)
          Csv.line(columns.map { |column| flat(row[column]) })
        end

        # A cell: Hashes and Arrays as JSON, times in ISO 8601, the rest as text.
        def flat(value)
          case value
          when Hash, Array then ActiveSupport::JSON.encode(value)
          when Time, DateTime, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
          else value
          end
        end
      end
    end
  end
end
