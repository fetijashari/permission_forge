# frozen_string_literal: true

module PermissionForge
  class VirtualFields
    # Finds virtual (non-column) fields a model exposes without declaring them
    # through extra_fields_method: attribute-API attributes and store accessors.
    #
    # It only reports names. Whether they are listed is VirtualFields'
    # decision (config.virtual_field_discovery), and a discovered name never
    # gets implicit access — ExtraFieldDefaults reads declared names only.
    #
    # Nested-attribute names (`<association>_attributes`) are left out on
    # purpose: PermitsAttributes filters those payloads by the nested model's
    # own Resource, and a field row on the parent would change that (an
    # Editable row passes the payload unfiltered, any other level does not
    # block it), so a level control for them would not mean what it says.
    #
    # @example
    #   PermissionForge::VirtualFields::Discovery.call(Customer) # => ["nickname", "theme"]
    #
    # @api private
    class Discovery
      # One private method per source; add a source by adding a name here.
      SOURCES = %i[attribute_api_names store_accessor_names].freeze

      def self.call(klass) = new(klass).call

      def initialize(klass)
        @klass = klass
      end

      # @return [Array<String>] discovered names, never a column
      def call
        SOURCES.flat_map { |source| send(source) }.uniq - @klass.column_names
      rescue StandardError
        []
      end

      private

      # `attribute :nickname, :string` with no column behind it.
      def attribute_api_names
        @klass.attribute_names
      end

      # `store_accessor :settings, :theme`, by reader name.
      def store_accessor_names
        return [] unless @klass.respond_to?(:stored_attributes)

        @klass.stored_attributes.flat_map do |store, keys|
          keys.flat_map { |key| accessor_names(store, key) }
        end
      end

      # stored_attributes records keys, not reader names: with prefix: true the
      # reader is `<store>_<key>`, with suffix: true `<key>_<store>`. Every
      # spelling that is a method counts (a bare key can also be a column,
      # which #call removes). Custom prefixes are not recorded anywhere, so
      # those accessors are not found.
      def accessor_names(store, key)
        [key.to_s, "#{store}_#{key}", "#{key}_#{store}"].select { |name| @klass.method_defined?(name) }
      end
    end
  end
end
