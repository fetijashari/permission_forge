Rails.application.configure do
  config.cache_classes = true
  # Eager load so the HTML admin controllers/views/helpers are loaded (and counted
  # by SimpleCov) — otherwise the entire admin-UI surface is excluded from coverage.
  config.eager_load = true
  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :none
  # log/test.log keeps warnings and errors only: request and SQL lines made it
  # 150 MB a run and cost CPU. A test that asserts on a log line installs its
  # own logger (and test_helper puts the suite's back after every test).
  config.log_level = :warn
  # test_helper loads db/schema.rb itself; the dummy has no db:test:prepare.
  config.active_record.maintain_test_schema = false
  # PfEncryptedNote (`encrypts :body`): the keys ActiveRecord::Encryption
  # needs, test-only values.
  config.active_record.encryption.primary_key = 'permission-forge-dummy-primary-key'
  config.active_record.encryption.deterministic_key = 'permission-forge-dummy-deterministic-key'
  config.active_record.encryption.key_derivation_salt = 'permission-forge-dummy-key-derivation-salt'
end
