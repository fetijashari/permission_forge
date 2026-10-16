# frozen_string_literal: true

module PermissionForge
  module Admin
    # Read-only reflection over the host app's ActiveRecord models, so the
    # admin UI only ever offers real models, columns and associations (no
    # free-text names that silently do nothing when misspelled).
    #
    # Columns are read through PermissionForge::SchemaRead: a model's column
    # list is compared with the database once per catalog (a column a
    # migration added while the process was up is offered, a removed one
    # flagged), and a name that is not a column is asked again once before
    # it is called virtual. Associations are the ones a rule's path can
    # follow (Operators::RulePath.unjoinable_cause): the builder never offers
    # one the applier refuses to join. Labels are Admin::FieldLabel's and
    # Admin::ModelLabel's.
    class ModelCatalog
      Column = Struct.new(:name, :label, :type, :enum_values, :user_reference, :virtual, keyword_init: true) do
        def user_reference? = user_reference
        def virtual? = virtual
      end

      Association = Struct.new(:name, :label, :class_name, :foreign_key, :macro, keyword_init: true) do
        # @param reflection [ActiveRecord::Reflection::AssociationReflection] (non-polymorphic)
        # @param target [Class] the reflection's resolved class
        # @param owner [Class] the model declaring the association
        def self.from(reflection, target, owner)
          name = reflection.name.to_s
          new(name: name, label: FieldLabel.for(owner, name).text, class_name: target.name,
              foreign_key: reflection.foreign_key.to_s, macro: reflection.macro)
        end
      end

      # A model the admin can protect. Its virtual fields come from
      # PermissionForge::VirtualFields.
      class ModelInfo
        attr_reader :klass

        # Whether a field with no active ResourceField row gets the implicit
        # read + edit entry from ExtraFieldDefaults right now.
        delegate :implicit_grant?, to: :virtual_fields

        def initialize(klass, configuration)
          @klass = klass
          @configuration = configuration
        end

        def name = @klass.name
        def label = ModelLabel.for(@klass).text
        def plural_label = ModelLabel.plural(@klass)

        # The model's columns (ignored_columns excluded), compared with the
        # database once for this catalog (PermissionForge::SchemaRead).
        def column_names
          @column_names ||= PermissionForge::SchemaRead.column_names(@klass, verify: true)
        end

        # Whether `name` is a column of the model, asked again once after the
        # schema is read again before "no" (PermissionForge::SchemaRead).
        def column?(name)
          PermissionForge::SchemaRead.column?(@klass, name.to_s, ignored: false)
        end

        # Columns PermissionForge manages (ignored_fields removed).
        def managed_column_names
          column_names - ignored_column_names
        end

        def ignored_column_names
          column_names & Array(@configuration.ignored_fields).map(&:to_s)
        end

        # Virtual fields the model declares through extra_fields_method.
        def declared_virtual_field_names
          virtual_fields.declared
        end

        # Declared + discovered (config.virtual_field_discovery), never a
        # column or an ignored field.
        def virtual_field_names
          virtual_fields.names
        end

        # Every field the admin configures: managed columns, then virtual fields.
        def managed_field_names
          managed_column_names + virtual_field_names
        end

        def virtual_field?(name)
          virtual_fields.include?(name)
        end

        # Whether code that reads a virtual field straight from the model gets
        # the field's level: its reader is wrapped on the class and
        # config.mask_virtual_attributes selects the model.
        def masked_on_model?(name)
          PermissionForge::Concerns::MaskedAttributes::VirtualReaders.masked?(@klass, name)
        end

        def columns
          @columns ||= managed_column_names.map { |name| column(name) } +
                       virtual_field_names.map { |name| virtual_column(name) }
        end

        def column(name)
          name = name.to_s
          return virtual_column(name) unless column?(name)

          Column.new(name: name, label: FieldLabel.for(@klass, name).text, type: column_type(name),
                     enum_values: enum_values(name), user_reference: user_reference?(name), virtual: false)
        end

        def associations
          @associations ||= @klass.reflect_on_all_associations.filter_map { |ref| build_association(ref) }
        end

        def association(name)
          associations.find { |association| association.name == name.to_s }
        end

        private

        def virtual_fields
          @virtual_fields ||= PermissionForge::VirtualFields.new(@klass, @configuration)
        end

        # nil for an association a rule's path cannot follow
        # (Operators::RulePath.unjoinable_cause: polymorphic, a
        # record-dependent scope, a broken :through or inverse_of, a class
        # that cannot be loaded): the applier refuses to join it.
        def build_association(ref)
          return if PermissionForge::Operators::RulePath.unjoinable_cause(ref)

          Association.from(ref, ref.klass, @klass)
        rescue *PermissionForge::Operators::RuleColumn::UNTELLABLE
          nil
        end

        def virtual_column(name)
          Column.new(name: name, label: FieldLabel.for(@klass, name).text, type: :string,
                     enum_values: nil, user_reference: false, virtual: true)
        end

        def column_type(name)
          @klass.type_for_attribute(name).type || :string
        rescue StandardError
          :string
        end

        def enum_values(name)
          return nil unless @klass.respond_to?(:defined_enums)

          @klass.defined_enums[name]&.keys
        end

        def user_reference?(name)
          user_class = @configuration.user_class.to_s
          @klass.reflect_on_all_associations(:belongs_to).any? do |ref|
            !ref.polymorphic? && ref.foreign_key.to_s == name && safe_klass(ref)&.name == user_class
          end
        end

        def safe_klass(ref)
          ref.klass
        rescue StandardError
          nil
        end
      end

      def initialize(configuration: PermissionForge.configuration)
        @configuration = configuration
      end

      # @return [Array<ModelInfo>] sorted by label
      def models
        @models ||= model_classes.map { |k| ModelInfo.new(k, @configuration) }.sort_by(&:label)
      end

      # @return [ModelInfo, nil] for a model name, whether or not it is listed.
      #   One ModelInfo per name for this catalog, so its reflection runs once
      #   however many Permission Sets contain the model.
      def find(name)
        key = name.to_s
        @found ||= {}
        @found.fetch(key) { @found[key] = build_info(key) }
      end

      private

      def build_info(name)
        klass = name.safe_constantize
        ModelInfo.new(klass, @configuration) if usable?(klass)
      end

      def model_classes
        classes = if @configuration.admin_model_resolver
                    Array(@configuration.admin_model_resolver.call)
                  else
                    default_model_classes
                  end
        classes.select { |k| usable?(k) }.uniq
      end

      def default_model_classes
        eager_load_app_models
        ActiveRecord::Base.descendants.select { |k| k.name.present? && app_model?(k) }
      end

      def usable?(klass)
        klass.is_a?(Class) && klass < ActiveRecord::Base && !klass.abstract_class? &&
          !klass.name.to_s.start_with?('PermissionForge::') && PermissionForge::SchemaRead.table?(klass, klass.table_name)
      rescue StandardError
        false
      end

      # Only models defined inside the host app (not gems/frameworks).
      def app_model?(klass)
        return true unless defined?(Rails) && Rails.root

        file = Object.const_source_location(klass.name)&.first
        file.nil? || file.start_with?(Rails.root.to_s)
      rescue StandardError
        true
      end

      def eager_load_app_models
        return unless defined?(Rails) && Rails.root && Rails.respond_to?(:autoloaders)

        eager_load_dir(Rails.autoloaders.main, Rails.root.join('app', 'models').to_s)
      rescue StandardError => e
        Rails.logger&.debug("[PermissionForge] model eager load skipped: #{e.class}")
      end

      def eager_load_dir(loader, dir)
        loader.eager_load_dir(dir) if File.directory?(dir) && loader.respond_to?(:eager_load_dir)
      end
    end
  end
end
