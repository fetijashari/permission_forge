# frozen_string_literal: true

module PermissionForge
  module Concerns
    module MaskedAttributes
      # `alias_attribute` on a model with MaskedAttributes. An alias is not a
      # field of its own: reading or writing it is reading or writing the
      # attribute it points to, at that attribute's level.
      #
      # Rails generates an alias's reader and writer to reach the attribute
      # directly — always on Rails 7.2 and later, and on 7.1 unless the model
      # defines the target's method itself — past the masked getter and the
      # guarded setter. So every alias gets a reader and a writer here that do
      # what the Rails version in use does, plus the guard (see
      # {AttributeAccessors} and {TargetMethodAccessors}).
      #
      # Where they live decides which of the model's own methods still run.
      # Rails keeps an alias's methods in the generated-attribute-methods
      # module of the class that declares it; the accessors go in a module
      # prepended to that very module. Whatever is found before Rails' own
      # alias methods — the class's methods, modules it includes, subclasses —
      # is found before these too, and `super` there reaches them.
      #
      # They never call `super` themselves: Ruby (3.4 at least) does not
      # notice that the method behind a module prepended to an already
      # included module was redefined, and would keep calling the old one.
      #
      # The other methods Rails generates for an alias (`mail?`, `mail_was`,
      # `mail_changed?`, `mail_before_type_cast`…) are already the target's
      # (`email?`, `email_was`…) under another name and are left alone.
      #
      # @api private
      module AliasAccess
        extend ActiveSupport::Concern

        # The module a class's alias readers and writers live in.
        class AccessorModule < Module; end

        # `id_value`, which Rails itself aliases to `id` (every model up to
        # Rails 8.1; from 8.2 only a model with a composite key, the others
        # get a plain reader), stays Rails': `id` is the primary key reader,
        # not the reader of a column called id.
        UNMASKED_TARGET = 'id'

        CREATION = Mutex.new
        private_constant :CREATION

        # Rails 7.2 and later: an alias reads and writes the attribute itself,
        # whatever reader or setter the model defines for the target. So do
        # these: through `read_attribute` when the target's reader is one the
        # concern masks, and past the write-back guard when the target is a
        # masked column.
        #
        # An alias declared by a class without the concern (a parent of the
        # one that has it) is reached by records of its other subclasses too.
        # For those, this is what Rails generates, word for word. Such a class
        # may declare the alias again with another target without the concern
        # hearing of it, so the target is asked of the declaring class at each
        # call, as Rails generates the alias's methods again there.
        module AttributeAccessors
          def self.define(klass, accessors, name, declared)
            accessors.redefine_method(name, &reader(klass, name, declared))
            accessors.redefine_method(:"#{name}=", &writer(klass, name, declared))
          end

          def self.reader(klass, name, declared)
            proc do
              target = klass.attribute_aliases.fetch(name, declared)
              if is_a?(MaskedAttributes) && pf_masked_reader?(target)
                read_attribute(target) { |missing| missing_attribute(missing, caller) }
              else
                _read_attribute(target) { |missing| missing_attribute(missing, caller) }
              end
            end
          end

          def self.writer(klass, name, declared)
            proc do |value|
              target = klass.attribute_aliases.fetch(name, declared)
              next if is_a?(MaskedAttributes) && pf_masked_column?(target) && pf_skip_masked_write?(target, value)

              _write_attribute(target, value)
            end
          end
        end

        # Rails 7.1: an alias calls the target's own reader or setter when the
        # model defines it (deprecated there) or the target is not an
        # attribute, and otherwise reads and writes the attribute as later
        # versions do. So do these.
        module TargetMethodAccessors
          def self.define(klass, accessors, name, declared)
            own = OwnMethods.new(klass, name, declared)
            attribute_reader = AttributeAccessors.reader(klass, name, declared)
            attribute_writer = AttributeAccessors.writer(klass, name, declared)
            accessors.redefine_method(name) do
              (reader = own.reader) ? send(reader) : instance_exec(&attribute_reader)
            end
            accessors.redefine_method(:"#{name}=") do |value|
              (setter = own.setter) ? send(setter, value) : instance_exec(value, &attribute_writer)
            end
          end

          # The target's methods an alias calls on Rails 7.1. The choice is
          # Rails' own (`alias_attribute_method_definition`), made once per
          # method on the class that declares the alias, with the concern's
          # modules looked past: seen by Rails, the masked getter is a method
          # the model defines.
          class OwnMethods
            def initialize(klass, name, declared)
              @klass = klass
              @name = name
              @declared = declared
              @choices = {}
            end

            # @return [String, nil] the reader to call; nil to read the attribute
            def reader
              own(target)
            end

            # @return [String, nil] the setter to call; nil to write the attribute
            def setter
              own("#{target}=")
            end

            private

            def target
              @klass.attribute_aliases.fetch(@name, @declared)
            end

            def own(method_name)
              @choices.fetch(method_name) { @choices[method_name] = (method_name if defined_by_the_model?(method_name)) }
            end

            def defined_by_the_model?(method_name)
              return true unless @klass.abstract_class? || @klass.has_attribute?(target)
              return false if ActiveRecord::AttributeMethods.dangerous_attribute_methods.include?(method_name)

              owner = owner_outside_the_concern(method_name)
              !owner.nil? && !owner.is_a?(ActiveRecord::AttributeMethods::GeneratedAttributeMethods)
            end

            def owner_outside_the_concern(method_name)
              method = @klass.instance_method(method_name)
              method = method.super_method while method && concern_module?(method.owner)
              method&.owner
            rescue NameError
              nil
            end

            def concern_module?(owner)
              [ColumnAccessors, VirtualReaders::ReaderModule, AccessorModule].any? { |kind| owner.is_a?(kind) }
            end
          end
        end

        class << self
          # Defines the reader and the writer of one alias `klass` declares.
          def define_accessors(klass, name, target)
            target = target.to_s
            return if target == UNMASKED_TARGET

            accessors.define(klass, accessor_module(klass), name.to_s, target)
          end

          # Covers the aliases `klass` itself declared, where Rails generates
          # their methods: in `klass`, not in the classes that inherit them.
          def mask_aliases_declared_by(klass)
            declared_aliases(klass).each { |name, target| define_accessors(klass, name, target) }
          end

          # @return [String, nil] the attribute `name` is an alias of on
          #   `klass`, following aliases of aliases
          def target(klass, name)
            aliases = klass.attribute_aliases
            target = aliases[name.to_s]
            target && chain_end(aliases, target)
          end

          # The attribute at the end of a chain of aliases that starts with
          # `target`. Bounded, so aliases that point at each other end too.
          def chain_end(aliases, target)
            aliases.size.times { target = aliases.fetch(target) { return target } }
            target
          end

          private

          def accessors
            @accessors ||= ActiveRecord.version < Gem::Version.new('7.2') ? TargetMethodAccessors : AttributeAccessors
          end

          # The class's own module, prepended to the module Rails generates
          # the class's attribute methods into.
          def accessor_module(klass)
            CREATION.synchronize do
              next klass.const_get(:MaskedAliasAccessors, false) if klass.const_defined?(:MaskedAliasAccessors, false)

              klass.const_set(:MaskedAliasAccessors, AccessorModule.new)
                   .tap { |accessors| klass.send(:generated_attribute_methods).prepend(accessors) }
            end
          end

          # Rails keeps the aliases each class declares in a registry of its
          # own; without one, the aliases that differ from the superclass's.
          def declared_aliases(klass)
            return registered_aliases(klass) if klass.respond_to?(:aliases_by_attribute_name)

            inherited = klass.superclass.attribute_aliases
            klass.attribute_aliases.reject { |name, target| inherited[name] == target }.to_a
          end

          # The registry keeps the old target of an alias that was declared
          # again with another one; only what the alias points to now counts.
          def registered_aliases(klass)
            current = klass.attribute_aliases
            klass.aliases_by_attribute_name
                 .flat_map { |target, names| names.map { |name| [name, target] } }
                 .select { |name, target| current[name] == target }
          end
        end

        # Extended into the model by ActiveSupport::Concern.
        module ClassMethods
          # The accessors are defined before Rails registers the alias, so
          # they are in place however soon Rails generates its own.
          def alias_attribute(new_name, old_name)
            AliasAccess.define_accessors(self, new_name, old_name)
            super
          end

          private

          # For the aliases that were declared before the concern was
          # included, each in the class that declared it: this class, its
          # ancestors (which do not have the concern) and the subclasses that
          # are loaded.
          def pf_mask_attribute_aliases
            lineage = ancestors.grep(Class).take_while { |klass| klass < ActiveRecord::Base }
            (lineage + descendants).each { |klass| AliasAccess.mask_aliases_declared_by(klass) }
          end
        end

        # `methods:` names that are aliases of an attribute the current user
        # may not read are dropped, the way the attribute itself is dropped
        # from the attribute names. Only a loaded attribute is: reading an
        # alias of one that was not loaded raises, as on any model.
        #
        # This module is included before MaskedAttributes itself (it is a
        # dependency): while the concern is being included, on another
        # thread, a record answers as it did without it.
        def serializable_hash(options = nil)
          return super unless is_a?(MaskedAttributes)

          super(pf_without_hidden_alias_methods(options))
        end

        private

        # The attribute an alias that points to `target` is judged as.
        def pf_alias_end(target)
          AliasAccess.chain_end(self.class.attribute_aliases, target)
        end

        def pf_without_hidden_alias_methods(options)
          methods = options && options[:methods]
          return options unless methods && (pf_guarded_user || pf_hide_without_user?) &&
                                PermissionForge.configuration.omit_hidden_in_attributes_hash

          options.merge(methods: Array(methods).reject { |name| pf_hidden_alias?(name) })
        end

        def pf_hidden_alias?(name)
          target = AliasAccess.target(self.class, name)
          target && has_attribute?(target) && pf_hidden_attribute?(target)
        end
      end
    end
  end
end
