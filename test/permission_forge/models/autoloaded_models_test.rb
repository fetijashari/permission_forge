# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # The nine models live in app/models/permission_forge and are autoloaded by
  # the host application, so a class body reads the configuration after the
  # host's config/initializers: the configurable associations are declared
  # once, with the configured class, and nothing re-declares them after boot
  # (no "method redefined" warnings, no rebinding initializer). The child
  # process checks — reload, eager load, a reference from an initializer —
  # are in test/permission_forge/install/model_loading_test.rb.
  class AutoloadedModelsTest < ActiveSupport::TestCase
    MODELS_DIR = File.expand_path('../../../app/models/permission_forge', __dir__)

    test 'every model is defined by its file under app/models/permission_forge' do
      PermissionForge::MODEL_NAMES.each do |name|
        path, = Object.const_source_location("PermissionForge::#{name}")

        assert_equal File.join(MODELS_DIR, "#{name.to_s.underscore}.rb"), path
      end
      assert_equal PermissionForge::MODEL_NAMES.size, Dir[File.join(MODELS_DIR, '*.rb')].size, 'one file per model'
    end

    test 'the models are managed by the application autoloader, not required by the gem' do
      PermissionForge::MODEL_NAMES.each do |name|
        path = File.join(MODELS_DIR, "#{name.to_s.underscore}.rb")

        assert_equal "PermissionForge::#{name}", Rails.autoloaders.main.cpath_expected_at(path)
      end
      entry_point = File.read(File.expand_path('../../../lib/permission_forge.rb', __dir__))

      assert_empty entry_point.scan(%r{^\s*require(?:_relative)?\s+['"][^'"]*models/}), 'lib/permission_forge.rb must not require a model'
    end

    test 'MODEL_NAMES names every model once' do
      models = PermissionForge::TestModels.all

      assert_equal PermissionForge::MODEL_NAMES.map { |name| "PermissionForge::#{name}" }, models.map(&:name)
      assert_equal 9, models.size
    end

    test 'the user association of an assignment is the configured user class, declared once' do
      [PermissionForge::PermissionSetUser, PermissionForge::PermissionSetGroupUser].each do |model|
        reflection = model.reflect_on_association(:user)

        assert_equal PermissionForge.configuration.user_class, reflection.class_name, model.name
        assert_equal User, reflection.klass
      end
    end

    test 'created_by and updated_by are the configured audit user class on every audited model' do
      audited = PermissionForge::TestModels.all.select { |m| m.include?(PermissionForge::Concerns::HasAuditTrail) }

      assert_equal 8, audited.size, 'every model but AuditEvent carries the audit trail'
      audited.each do |model|
        %i[created_by updated_by].each do |name|
          assert_equal PermissionForge.configuration.audit_user_class, model.reflect_on_association(name).class_name,
                       "#{model.name}##{name}"
        end
      end
    end

    test 'nothing rebinds an association after boot' do
      assert_not PermissionForge::PermissionSet.respond_to?(:rebind_audit_associations!)
      assert_not PermissionForge::Engine.respond_to?(:rebind_configurable_associations, true)
      names = PermissionForge::Engine.initializers.map(&:name)

      assert_not_includes names, 'permission_forge.rebind_associations'
      assert_not_includes names, 'permission_forge.load_models'
    end

    test 'a Resource name and a declared controller resource share one format' do
      assert_same PermissionForge::RESOURCE_NAME_FORMAT, PermissionForge::Resource::NAME_FORMAT
      assert_same PermissionForge::RESOURCE_NAME_FORMAT, PermissionForge::ControllerActions::RESOURCE_FORMAT
    end

    test 'every model reads its table name through the prefix on each call' do
      PermissionForge::TestModels.all.each do |model|
        bare = model.table_name

        assert_not bare.start_with?('pfx_'), model.name
        PermissionForge.configuration.table_name_prefix = 'pfx_'

        assert_equal "pfx_#{bare}", model.table_name, model.name
      ensure
        PermissionForge.configuration.table_name_prefix = ''
      end
    end

    test 'the tenant scope is declared by the class body, once, after the model\'s own callbacks' do
      PermissionForge::TestModels.all.each do |model|
        assert model.tenant_scoping_applied?, model.name
        assert_equal 1, model.default_scopes.size, "#{model.name} carries a single default scope"
      end
      # Declared last: acts_as_tenant's validations run after the model's own.
      last = PermissionForge::PermissionSetUser._validate_callbacks.to_a.last

      assert_kind_of Proc, last.filter, 'acts_as_tenant validates with a block'
      assert_match(/acts_as_tenant/, last.filter.source_location.first)
    end

    test 'a model name that cannot be resolved explains where the models may be referenced' do
      error = assert_raises(NameError) { PermissionForge.const_missing(:PermissionSet) }

      assert_equal :PermissionSet, error.name
      assert_match(%r{config/initializers}, error.message)
      assert_match(/engine or railtie initializer/, error.message)
      assert_match(/Rails\.application\.config\.to_prepare/, error.message)
      assert_match(/Rails\.autoloaders\.main\.on_load\('PermissionForge::PermissionSet'\)/, error.message)
      assert_match(/after_initialize runs once/, error.message)
      # Any other name is a plain NameError.
      assert_match(/uninitialized constant PermissionForge::Nope/, assert_raises(NameError) { PermissionForge::Nope }.message)
    end
  end
end
