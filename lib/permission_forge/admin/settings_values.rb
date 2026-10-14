# frozen_string_literal: true

module PermissionForge
  module Admin
    # Turns raw configuration values into the comparable, display-ready values
    # SettingsCatalog shows, and into Ruby source for the "How to change"
    # snippet. Never exposes secrets or lambda bodies.
    class SettingsValues
      # Normalizer per Definition#type; any other type is shown as-is.
      NORMALIZERS = {
        secret: :secret_set?, hook: :hook_state, enum: :enum_value, names: :names_value,
        list: :list_value, map: :map_value, class: :class_value, num: :number_value
      }.freeze

      # Per-key enum readings that differ from value.to_s (nil = no override).
      # false/nil read as 'off', an Array as 'list'.
      OFF_AUTO_LIST = lambda { |value|
        next 'list' if value.is_a?(Array)

        'off' if [false, nil].include?(value)
      }

      ENUM_OVERRIDES = {
        'auto_apply_masked_attributes' => OFF_AUTO_LIST,
        'mask_virtual_attributes' => OFF_AUTO_LIST,
        'audit_events' => :to_s.to_proc,
        'cache_backend' => ->(value) { value.class.name unless value.is_a?(Symbol) || value == true }
      }.freeze

      VARIANT_SAMPLES = %w[owner_id amount_cents customer_uuid price_in_cents created_on].freeze

      # Comparable, display-ready values. Never exposes secrets or lambda bodies.
      def normalize(definition, value)
        normalizer = NORMALIZERS[definition.type]
        normalizer ? send(normalizer, definition, value) : value
      end

      # Ruby source for a raw configuration value.
      def ruby_literal(value)
        case value
        when nil then 'nil'
        when Symbol then ":#{value}"
        when String then "'#{value}'"
        when Array then array_literal(value)
        when Hash then '{ ... }'
        when ActiveSupport::Duration then duration_literal(value)
        else value.inspect
        end
      end

      private

      def secret_set?(_definition, value)
        value.present?
      end

      # A duration (90.days) reads as its seconds.
      def number_value(_definition, value)
        value.is_a?(ActiveSupport::Duration) ? value.to_i : value
      end

      # 90.days, 1.day + 12.hours
      def duration_literal(value)
        value.parts.map { |unit, count| "#{count}.#{unit}" }.join(' + ')
      end

      def names_value(_definition, value)
        (value.try(:keys) || Array(value)).map(&:to_s)
      end

      def list_value(_definition, value)
        value.nil? ? nil : Array(value).map { |item| pattern_text(item) }
      end

      def class_value(_definition, value)
        value&.to_s&.delete_prefix('::')
      end

      def enum_value(definition, value)
        override = ENUM_OVERRIDES[definition.key]&.call(value)
        return override if override

        value == true ? 'auto' : value.to_s
      end

      def map_value(definition, value)
        return [] if value.blank?

        key = definition.key
        value.map { |pattern, target| [pattern_text(pattern), map_target(key, pattern, target)] }
      end

      def pattern_text(pattern)
        pattern.is_a?(Regexp) ? "/#{pattern.source}/" : pattern.to_s
      end

      def map_target(key, pattern, target)
        describe_target(pattern, target)
      rescue StandardError
        key == 'field_variant_mappings' ? 'custom code' : target.to_s
      end

      # Plain values as text; callables as "sample → result" on a sample
      # column name the pattern matches, else 'custom code'.
      def describe_target(pattern, target)
        return target.to_s unless target.respond_to?(:call)
        return target.name.to_s if target.is_a?(Class)

        sample = VARIANT_SAMPLES.find { |candidate| candidate.match?(pattern) } if pattern.is_a?(Regexp)
        sample ? "#{sample} → #{target.call(sample)}" : 'custom code'
      end

      # :default (gem's own lambda, or nil where nil means built-in behaviour),
      # :custom (host lambda), :none (nil with no fallback).
      def hook_state(definition, value)
        return (definition.nil_label == :default ? :default : :none) if value.nil?

        file = value.respond_to?(:source_location) ? value.source_location&.first.to_s : ''
        file.include?('lib/permission_forge/configuration') ? :default : :custom
      end

      def array_literal(value)
        return "%w[#{value.join(' ')}]" if value.all?(String)
        return "%i[#{value.join(' ')}]" if value.all?(Symbol)

        value.inspect
      end
    end
  end
end
