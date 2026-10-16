# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # A model takes the user class, the audit user class and the tenant model
  # from the configuration as it loads. A setting changed afterwards changes
  # nothing in the loaded class (a development reload picks it up; production
  # never does): PermissionForge.configure says so, once per setting.
  class ModelBindingsTest < ActiveSupport::TestCase
    BOUND = %i[user_class audit_user_class tenant_model].freeze

    setup do
      # Every model is loaded (the suite references them all; a single-file run may not have).
      PermissionForge::TestModels.all
      @bound = BOUND.to_h { |setting| [setting, PermissionForge.configuration.public_send(setting)] }
    end

    teardown do
      @bound.each { |setting, value| PermissionForge.configuration.public_send(:"#{setting}=", value) }
    end

    test 'nothing to report while the configuration is what the models declared' do
      assert_empty ModelBindings.mismatches
    end

    test 'a user_class set after the models loaded is reported with what they declared' do
      PermissionForge.configuration.user_class = 'TextKeyUser'

      sentences = ModelBindings.mismatches

      assert_equal 1, sentences.size
      assert_match(/config\.user_class is "TextKeyUser"/, sentences.first)
      assert_match(/PermissionForge::PermissionSetUser, PermissionForge::PermissionSetGroupUser loaded with "User"/, sentences.first)
      assert_match(%r{config/initializers}, sentences.first)
    end

    test 'an audit_user_class set after the models loaded is reported for every audited model' do
      PermissionForge.configuration.audit_user_class = 'TextKeyUser'

      sentence = ModelBindings.mismatches.sole

      assert_match(/config\.audit_user_class is "TextKeyUser"/, sentence)
      assert_match(/PermissionForge::PermissionSet, .*PermissionForge::PermissionSetRule loaded with "User"/, sentence)
      assert_no_match(/AuditEvent/, sentence)
    end

    test 'a tenant_model switched off after the models loaded is reported' do
      PermissionForge.configuration.tenant_model = nil

      sentence = ModelBindings.mismatches.sole

      assert_match(/config\.tenant_model is nil/, sentence)
      assert_match(/loaded with "Account"/, sentence)
    end

    test 'PermissionForge.configure logs each difference' do
      log = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log)

      PermissionForge.configure { |config| config.user_class = 'TextKeyUser' }

      assert_equal 1, log.string.scan('[PermissionForge] config.user_class is "TextKeyUser"').size
      assert_match(/keeps what it declared until it is loaded again/, log.string)
    ensure
      Rails.logger = original
    end

    # R2 review, P1-6: models loaded with another tenant model (or none)
    # are not isolated as configured — access across tenants.
    test 'a tenant_model mismatch is a SECURITY warning; a user_class one is not' do
      log = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log)

      PermissionForge.configure { |config| config.tenant_model = nil }
      PermissionForge.configuration.tenant_model = @bound[:tenant_model]
      PermissionForge.configure { |config| config.user_class = 'TextKeyUser' }

      assert_includes log.string, '[PermissionForge] SECURITY warning: config.tenant_model is nil'
      assert_includes log.string, '[PermissionForge] config.user_class is "TextKeyUser"'
    ensure
      Rails.logger = original
    end

    test 'the check loads no model' do
      assert_equal PermissionForge::MODEL_NAMES.size, ModelBindings.loaded_models.size
      assert(ModelBindings.loaded_models.all? { |model| model < ActiveRecord::Base })
    end
  end
end
