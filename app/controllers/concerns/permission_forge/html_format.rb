module PermissionForge
  # The admin screens answer HTML, plus the exports an action declares
  # (pf_exports). Any other Accept header or extension — a scanner's
  # application/json, text/csv on a form — is answered in HTML: the admin
  # has no other templates, and a failing form must not end in a missing
  # template (a 500). Runs first, before anything renders.
  #
  # @example
  #   pf_exports %i[csv json], only: %i[index holdings]
  #
  # @api private
  module HtmlFormat
    extend ActiveSupport::Concern

    included do
      # action name => the formats it answers besides HTML
      class_attribute :pf_export_formats, instance_writer: false, default: {}.freeze
      prepend_before_action :pf_negotiate_html
    end

    class_methods do
      # @param formats [Array<Symbol>] e.g. %i[csv]
      # @param only [Symbol, Array<Symbol>] the actions that export them
      def pf_exports(formats, only:)
        exports = Array(only).to_h { |action| [action.to_s, formats.map(&:to_s).freeze] }
        self.pf_export_formats = pf_export_formats.merge(exports).freeze
      end
    end

    private

    # The first acceptable format that is HTML or an export of the action
    # (as respond_to would choose), else HTML.
    def pf_negotiate_html
      exports = pf_export_formats.fetch(action_name, [])
      chosen = request.formats.map { |format| format.symbol.to_s }.find { |name| name == 'html' || exports.include?(name) }
      request.format = (chosen || 'html').to_sym
    end
  end
end
