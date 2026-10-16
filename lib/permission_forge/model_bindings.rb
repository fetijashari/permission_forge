# frozen_string_literal: true

require_relative 'warnings'

module PermissionForge
  # What a model took from the configuration as it loaded — the user class of
  # an assignment (PermissionSetUser#user, PermissionSetGroupUser#user), the
  # audit user class (created_by / updated_by) and the tenant model
  # (HasTenantScoping) — against what the configuration says now. A setting
  # changed after the class loaded (a PermissionForge.configure or a setter
  # in after_initialize, a console) changes nothing in the class: a
  # development reload picks it up, an eager-loaded production process never
  # does. The engine warns about each difference (Warnings.emit) once the
  # host's after_initialize blocks have run, and PermissionForge.configure
  # does too. Nothing here loads a model. (table_name_prefix is not
  # compared: table_name is a method that reads it on every call.)
  #
  # @api private
  module ModelBindings
    # The settings a model declares as it loads, each with the association
    # that carries it (the tenant is read from HasTenantScoping).
    ASSOCIATIONS = { user_class: :user, audit_user_class: :created_by }.freeze

    class << self
      # One sentence per setting that loaded models declared differently.
      #
      # @param config [Configuration]
      # @return [Array<String>]
      def mismatches(config = PermissionForge.configuration)
        differences(config).map { |difference, models| sentence(difference, models) }
      end

      # Warns about every mismatch, one key per setting.
      #
      # @param config [Configuration]
      # @return [void]
      def warn!(config = PermissionForge.configuration)
        differences(config).each do |difference, models|
          Warnings.emit("model_bindings.#{difference.first}", sentence(difference, models))
        end
      end

      # The model classes already loaded, without loading one.
      #
      # @return [Array<Class>]
      def loaded_models
        MODEL_NAMES.select { |name| PermissionForge.autoload?(name).nil? && PermissionForge.const_defined?(name, false) }
                   .map { |name| PermissionForge.const_get(name) }
      end

      private

      # { [setting, what the configuration says, what the models declared] =>
      # the model names } for every difference.
      def differences(config)
        found = Hash.new { |hash, key| hash[key] = [] }
        loaded_models.each do |model|
          declared_otherwise(model, config).each do |setting, declared|
            found[[setting, config.public_send(setting), declared]] << model.name
          end
        end
        found
      end

      # [setting, what the model declared] for each setting the model
      # declared and the configuration now says differently. A model without
      # the association (a PermissionSet has no :user) declares nothing.
      def declared_otherwise(model, config)
        declared(model).reject { |setting, value| value == current(config, setting) }
      end

      def declared(model)
        pairs = ASSOCIATIONS.filter_map do |setting, association|
          reflection = model.reflect_on_association(association)
          [setting, reflection.class_name] if reflection
        end
        pairs << [:tenant_model, model.tenant_scoping_model]
      end

      def current(config, setting)
        return (config.tenant_model.to_s if config.tenant_enabled?) if setting == :tenant_model

        config.public_send(setting).to_s
      end

      def sentence(difference, models)
        setting, now, declared = difference
        "config.#{setting} is #{now.inspect} but #{models.join(', ')} loaded with " \
          "#{declared.inspect}: a loaded class keeps what it declared until it is loaded again (a code reload in " \
          'development; never in an eager-loaded production process). Configure PermissionForge in ' \
          'config/initializers.'
      end
    end
  end
end
