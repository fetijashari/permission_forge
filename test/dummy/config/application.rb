require_relative 'boot'

require 'rails'
require 'active_model/railtie'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_view/railtie'

Bundler.require(*Rails.groups)
require 'rails-i18n'
require 'permission_forge'

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.api_only = false
    config.root = File.expand_path('..', __dir__)
    config.i18n.available_locales = %i[en sq mk]
    config.i18n.default_locale = :en
  end
end
