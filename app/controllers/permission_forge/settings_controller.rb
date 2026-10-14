module PermissionForge
  # Read-only view of PermissionForge's configuration, with health checks and
  # copy-paste instructions for changing each value in the initializer.
  #
  # @api private
  class SettingsController < ApplicationController
    def show
      @catalog = pf_settings_catalog
      @query = params[:q].to_s.strip.downcase
      @changed_only = params[:changed] == '1'
      @focus = @catalog.row(params[:focus])&.key
      @sections = visible_sections(@catalog.sections)
    end

    private

    def visible_sections(sections)
      sections.filter_map do |section, rows|
        shown = rows.select { |row| visible?(row) }
        [section, shown] if shown.any?
      end
    end

    def visible?(row)
      return false if @changed_only && !row.changed?
      return true if @query.empty?

      text = [row.key, t("permission_forge.settings.items.#{row.key}.name", default: ''),
              t("permission_forge.settings.items.#{row.key}.desc", default: '')].join(' ').downcase
      text.include?(@query)
    end
  end
end
