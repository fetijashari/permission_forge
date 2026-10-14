PermissionForge.configure do |config|
  config.user_class = 'User'
  config.current_user_resolver = -> { Current.user }
  config.cache_backend = :memory
  config.table_name_prefix = ''
  config.audit_trail_enabled = false
  config.http_basic_auth_enabled = false
  config.api_enabled = true
  config.api_auth = ->(_controller) { true }
  # Off at boot, not only in test_helper's setup: Rails copies
  # config.filter_parameters into ActiveRecord::Base.filter_attributes once,
  # when ActiveRecord::Base loads (after the initializers, now that the
  # models are autoloaded). The masking tests inspect records and would see
  # [FILTERED] in place of the masked values they look at.
  config.filter_parameters_integration = false
end
