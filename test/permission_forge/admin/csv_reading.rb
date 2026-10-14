# frozen_string_literal: true

require 'strscan'

module PermissionForge
  module Admin
    # Reads the admin's CSV exports back in tests (the csv gem is not a
    # dependency): RFC 4180 fields, quoted or not, CRLF line ends.
    module CsvReading
      FIELD = /"((?:[^"]|"")*)"|([^,\r\n]*)/

      module_function

      # @return [Array<Array<String>>]
      def rows(text)
        scanner = StringScanner.new(text.to_s)
        rows = []
        rows << read_row(scanner) until scanner.eos?
        rows
      end

      def read_row(scanner)
        row = []
        loop do
          scanner.scan(FIELD)
          row << (scanner[1] ? scanner[1].gsub('""', '"') : scanner[2].to_s)
          break unless scanner.scan(',')
        end
        scanner.scan("\r\n")
        row
      end

      # An export: [metadata Hash, column names, data rows].
      def export(text)
        meta_text, table = text.split("\r\n\r\n", 2)
        table_rows = rows(table)
        [rows(meta_text).to_h, table_rows.first, table_rows.drop(1)]
      end
    end
  end
end
