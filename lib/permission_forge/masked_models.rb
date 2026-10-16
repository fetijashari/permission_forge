# frozen_string_literal: true

require_relative 'database_reach'

module PermissionForge
  # Auto-applied masking: mixes MaskedAttributes into the models
  # config.auto_apply_masked_attributes selects and wraps the virtual readers
  # of the models config.mask_virtual_attributes selects. Each setting takes
  # its models from the Resource rows (:auto / true) or from a list. Called
  # by MaskingSync (at boot, after a Resource row names a model, and when
  # another process named one).
  #
  # @api private
  module MaskedModels
    # Setting values that switch a step off.
    OFF = [false, nil].freeze

    class << self
      # @return [Boolean] whether either setting is on (MaskingSync does
      #   nothing otherwise)
      def enabled?(config = PermissionForge.configuration)
        settings(config).any? { |setting| !OFF.include?(setting) }
      end

      # Whether a setting that is on takes its models from the Resource rows:
      # a row committed in another process can then name a model this process
      # has not masked. False when every setting that is on is a list — the
      # models are fixed by the configuration.
      #
      # @return [Boolean]
      def row_driven?(config = PermissionForge.configuration)
        settings(config).any? { |setting| !OFF.include?(setting) && !setting.is_a?(Array) }
      end

      # Includes the concern on every selected model, then wraps the virtual
      # readers of every selected model that has it (applied here, or
      # included by the model itself). Idempotent. A model that cannot be
      # masked (its table is missing, its database is down) is logged and
      # skipped: the others are still masked.
      #
      # @param only [String, nil] one model, as long as the settings select it
      # @return [Boolean] true when every selected model is masked; false when
      #   the Resource rows could not be read (no table yet, no database), a
      #   model could not be masked, or a listed name is no model here
      #   (MaskingSync then tries again)
      def apply(only: nil)
        config = PermissionForge.configuration
        return true unless enabled?(config)
        # No database to use (not configured, unreachable), or no table yet.
        return false unless DatabaseReach.table_exists?(PermissionForge::Resource)

        apply_selected(config, only).all? & unknown_listed_names(config, only).empty?
      rescue *DatabaseReach::READ_ERRORS
        # The database went away while the rows were read.
        false
      end

      # @return [Boolean, nil] false when the model is left unmasked
      def apply_concern(model_name)
        klass = model_class(model_name)
        return if klass.nil? || klass.abstract_class?
        return if masked_class?(klass)

        # Including the concern runs its `included` block after the module is
        # in the ancestors: a block that failed there (the table could not be
        # read) leaves a class every later include skips. Never start one
        # that cannot finish.
        why = unmaskable_reason(klass)
        if why
          warn_unmaskable(klass, why)
          return false
        end

        klass.include(PermissionForge::Concerns::MaskedAttributes)
        unmaskable_warned.delete(klass.name)
      end

      # Wraps the virtual readers of a model that has MaskedAttributes. The
      # wrappers re-check config.mask_virtual_attributes on every call. A
      # model whose extra_fields_method raises keeps its declared readers
      # unwrapped, and pf_mask_virtual_readers logs a SECURITY warning.
      #
      # @return [Array<String>, nil] the names wrapped
      def mask_virtual_readers(model_name)
        klass = model_class(model_name)
        return unless klass.respond_to?(:pf_mask_virtual_readers)
        return unless PermissionForge.configuration.mask_virtual_attributes_for?(klass.name)

        klass.pf_mask_virtual_readers
      end

      # Whether the model `model_name` names has the concern in this process
      # (applied, or included by the model or a class it inherits from);
      # false for a name that resolves to no model here.
      #
      # @param model_name [String]
      # @return [Boolean]
      def masked?(model_name)
        klass = model_class(model_name)
        klass ? masked_class?(klass) : false
      end

      # Warns again about a model that still cannot be masked (MaskingSync.reset!).
      def reset_warnings!
        unmaskable_warned.clear
      end

      private

      def settings(config)
        [config.auto_apply_masked_attributes, config.mask_virtual_attributes]
      end

      # The concern on every selected model, then the virtual readers (the
      # names of both read first).
      #
      # @return [Array<Boolean>] whether each step left its model masked
      def apply_selected(config, only)
        concern = model_names(config.auto_apply_masked_attributes, only: only)
        virtual = model_names(config.mask_virtual_attributes, only: only)
        concern.map { |name| guarded(name) { apply_concern(name) } } +
          virtual.map { |name| guarded(name) { mask_virtual_readers(name) } }
      end

      # One model's failure is logged and the loop goes on; a
      # ConfigurationError (the setup is wrong, not the model) still stops the
      # boot, as everywhere in BootChecks.
      def guarded(name)
        yield != false
      rescue PermissionForge::ConfigurationError
        raise
      rescue StandardError => e
        warn_unmaskable(model_class(name) || name, "#{e.class}: #{e.message}")
        false
      end

      # The models a setting selects: none when it is off, its list, or the
      # names of the Resource rows — narrowed to `only`.
      def model_names(setting, only: nil)
        return [] if OFF.include?(setting)
        return listed_names(setting, only) if setting.is_a?(Array)

        only ? Array(only).map(&:to_s) : resource_names
      end

      def listed_names(list, only)
        list = list.map(&:to_s)
        only ? Array(only).map(&:to_s) & list : list
      end

      # The names a list setting gives that resolve to no model here (a typo,
      # a class not loaded yet), each logged once. A name a Resource row
      # gives (:auto) may name a controller-only resource: not reported.
      #
      # @return [Array<String>]
      def unknown_listed_names(config, only)
        { 'auto_apply_masked_attributes' => config.auto_apply_masked_attributes,
          'mask_virtual_attributes' => config.mask_virtual_attributes }.flat_map do |setting, value|
          next [] unless value.is_a?(Array)

          listed_names(value, only).reject { |name| model_class(name) }.each { |name| warn_unknown(setting, name) }
        end
      end

      def warn_unknown(setting, name)
        return if unmaskable_warned.put_if_absent("#{setting}=#{name}", true)

        Warnings.emit("masked_models.unknown_listed.#{setting}=#{name}",
                      "'#{name}' is listed in config.#{setting} but is no model in this process: nothing is " \
                      'masked for it. It is tried again at the next request or job.', severity: :security)
      end

      # Every tenant's rows: a model is masked for the whole process.
      def resource_names
        if PermissionForge.configuration.tenant_enabled? && defined?(ActsAsTenant)
          ActsAsTenant.without_tenant { PermissionForge::Resource.distinct.pluck(:name) }
        else
          PermissionForge::Resource.distinct.pluck(:name)
        end
      end

      # The class, or a class it inherits from, has the concern applied. A
      # subclass is masked through its parent (the concern is never included
      # into a subclass) and may have a Resource row of its own (STI).
      def masked_class?(klass)
        PermissionForge::Concerns::MaskedAttributes.applied_in_chain?(klass)
      end

      # Only reached when no class in the chain has the concern applied: the
      # module in the ancestors then means an include that failed halfway.
      #
      # @return [String, nil] why the concern cannot be included now
      def unmaskable_reason(klass)
        unreadable_table(klass) ||
          ('an earlier attempt failed halfway; restart the process' if klass.include?(PermissionForge::Concerns::MaskedAttributes))
      end

      # Why the table cannot be read, nil when it exists and can be. A table
      # found missing is looked up again next time (the cached answer is
      # dropped): a migration may run. Its database may be another one than
      # the gem's (a host on several databases); a check that raised names
      # the error (DatabaseReach): the model's own table_name, its database
      # not configured.
      def unreadable_table(klass)
        cause = nil
        return if DatabaseReach.table_exists?(klass) { |error| cause = error }

        klass.reset_column_information
        cause ? "its table cannot be read (#{cause.class}: #{cause.message.lines.first&.strip})" : 'its table cannot be read'
      end

      # Warns once per model and process (MaskingSync retries every request).
      def warn_unmaskable(klass, why)
        name = klass.to_s
        return if unmaskable_warned.put_if_absent(name, true)

        Warnings.emit("masked_models.unmaskable.#{name}",
                      "#{name} has a Resource row but #{why}: its columns are NOT masked in this process. " \
                      'It is tried again at the next request or job.', severity: :security)
      end

      # The models (and unknown listed names) whose warning this process has logged.
      def unmaskable_warned
        @unmaskable_warned ||= Concurrent::Map.new
      end

      def model_class(model_name)
        klass = model_name.to_s.safe_constantize
        klass if klass.is_a?(Class) && klass < ActiveRecord::Base
      end
    end
  end
end
