module PermissionForge
  # Per-browser admin preferences, stored in cookies scoped to the engine's
  # mount path: colour theme and dismissed helper banners.
  #
  # @api private
  class PreferencesController < ApplicationController
    HELP_KEY = /\A[a-z_]{1,40}\z/

    def update
      theme = params[:theme]
      pf_cookie(:pf_theme, theme) if THEMES.include?(theme.to_s)
      dismiss_help(params[:dismiss_help].to_s)
      redirect_to pf_back_or(permission_forge.root_path)
    end

    private

    # Blank or malformed keys are ignored.
    def dismiss_help(key)
      return unless key.match?(HELP_KEY)

      keys = (pf_dismissed_help + [key]).uniq.last(30)
      pf_cookie(:pf_help, keys.join(','))
    end
  end
end
