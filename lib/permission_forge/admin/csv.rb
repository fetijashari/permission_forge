# frozen_string_literal: true

module PermissionForge
  # @api private
  module Admin
    # The one CSV writer of the admin exports (audit trail, audit log, who
    # holds what): RFC 4180 quoting, CRLF line ends, and a leading apostrophe
    # on any value a spreadsheet would run as a formula (CSV injection).
    module Csv
      # Characters that make Excel, LibreOffice or Google Sheets treat a cell
      # as a formula (or a DDE call) when they open the file — also after
      # leading spaces or line breaks, which some of them skip (and which the
      # audit columns get when a leading tab is cleaned into a space).
      FORMULA_START = /\A(?:[\t\r]|\s*[=+\-@])/
      NEEDS_QUOTES = /[",\r\n]/
      LINE_END = "\r\n"

      module_function

      # @param value [Object] anything; nil is an empty cell
      # @return [String] the cell as written to the file
      def cell(value)
        text = value.to_s
        text = "'#{text}" if text.match?(FORMULA_START)
        text.match?(NEEDS_QUOTES) || text != text.strip ? %("#{text.gsub('"', '""')}") : text
      end

      # @param values [Array] the cells of one row
      # @return [String] the row, with its line end
      def line(values)
        values.map { |value| cell(value) }.join(',') << LINE_END
      end

      # @param rows [Array<Array>]
      # @return [String]
      def document(rows)
        rows.map { |row| line(row) }.join
      end
    end
  end
end
