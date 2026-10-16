require_relative 'boot'

require 'rails'
require 'active_model/railtie'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_view/railtie'

Bundler.require(*Rails.groups)
# Never rails-i18n here: the suite proves that every string the admin, the
# API, a CSV or an audit sentence shows in sq/mk is the gem's own
# (test_helper asserts it is absent; html/locale_leak_test.rb).
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
