# frozen_string_literal: true

module PermissionForge
  module Concerns
    module MaskedAttributes
      # Model-level masking of virtual (non-column) readers: plain methods,
      # store accessors and attribute-API attributes. Part of MaskedAttributes;
      # opt-in through config.mask_virtual_attributes.
      #
      # Wrapping a reader is permanent for the class, the decision is not:
      # every wrapper asks the configuration on each call, so a wrapped class
      # behaves like an unwrapped one while the config does not select it.
      #
      # Not covered: write-back protection for virtual setters.
      #
      # @example
      #   Customer.pf_mask_virtual_readers            # the engine does this at boot
      #   customer.full_address                       # hidden / masked / raw for current_user
      #   customer.pf_without_virtual_masking { customer.full_address }  # always raw
      #
      # @api private
      module VirtualReaders
        extend ActiveSupport::Concern

        # The module a class's wrappers live in, prepended to that class.
        class ReaderModule < Module; end

        # Values a mask strategy can be applied to. Anything else (arrays,
        # hashes, records, booleans, dates) is hidden instead of masked: a mask
        # of its to_s would be meaningless and could leak.
        MASKABLE_TYPES = [String, Symbol, Numeric].freeze

        # Stands in for an unmaskable value, so the guard decides without the
        # real value ever being stringified. Not a String: MaskValue masks the
        # to_s of what it is given, so no mask can be this object.
        PROBE = Object.new.freeze

        READER_NAME = /\A[a-z_][a-zA-Z0-9_]*\z/
        REQUIRED_PARAMETERS = %i[req keyreq].freeze

        # ExecutionState slot: set (by identity) of the records inside
        # pf_without_virtual_masking.
        UNMASKED_KEY = :pf_unmasked_virtual_records

        # Whether reading `name` on a record of `klass` is masked right now:
        # the call reaches a wrapper on that class and
        # config.mask_virtual_attributes selects the model. False for a class
        # without the concern.
        def self.masked?(klass, name)
          klass.respond_to?(:pf_virtual_reader_masked?) &&
            PermissionForge.configuration.mask_virtual_attributes_for?(klass.name) &&
            klass.pf_virtual_reader_masked?(name)
        end

        # Extended into the model by ActiveSupport::Concern.
        module ClassMethods
          # Wraps virtual readers so they return what the current user may see.
          # Idempotent. Never wraps the primary key, a column, a method
          # ActiveRecord::Base defines, a method that does not exist or one
          # that needs arguments.
          #
          # @param names [Array<String, Symbol>] defaults to the virtual fields
          #   the admin lists for the model (declared, plus discovered ones
          #   while config.virtual_field_discovery is on). When the model's
          #   extra_fields_method raises, its declared names are not wrapped
          #   and the log says so.
          # @return [Array<String>] the names this call wrapped
          def pf_mask_virtual_readers(names = pf_virtual_field_names(wrapping: true))
            pf_virtual_readers(names).reject { |name| pf_virtual_reader_masked?(name) }
                                     .each { |name| pf_define_virtual_reader(name) }
          end

          # @return [Array<String>] the names in `names` that have a reader this
          #   concern can mask, wrapped already or not
          def pf_virtual_readers(names = pf_virtual_field_names)
            names.map(&:to_s).uniq.select { |name| pf_virtual_reader?(name) }
          end

          # @return [Array<String>] every wrapped reader, inherited ones included
          def pf_masked_virtual_readers
            ancestors.grep(ReaderModule).flat_map { |readers| readers.instance_methods(false) }.map(&:to_s).uniq
          end

          # True when calling `name` on this class reaches a wrapper: its own,
          # or one inherited from a superclass it does not override.
          def pf_virtual_reader_masked?(name)
            method_defined?(name) && instance_method(name).owner.is_a?(ReaderModule)
          end

          private

          # `wrapping` — the names are about to be wrapped, so an error from the
          # model's extra_fields_method (logged by VirtualFields#extra, which
          # then gives no declared names) leaves readers unmasked.
          def pf_virtual_field_names(wrapping: false)
            fields = PermissionForge::VirtualFields.new(self, PermissionForge.configuration)
            names = fields.names
            error = fields.extra_error
            pf_warn_virtual_readers_unmasked(error) if wrapping && error
            names
          end

          def pf_warn_virtual_readers_unmasked(error)
            method = PermissionForge.configuration.extra_fields_method
            PermissionForge::Warnings.emit("virtual_readers.unmasked.#{name}",
                                           "the virtual readers #{name} declares are NOT masked on the model: " \
                                           "#{name}.#{method} raised #{error.class}: #{error.message}. Fix it and " \
                                           'restart, or call pf_mask_virtual_readers with explicit names.',
                                           severity: :security)
          end

          def pf_virtual_reader?(name)
            return false unless name.match?(READER_NAME)
            return false if Array(primary_key).map(&:to_s).include?(name) || columns_hash.key?(name)

            attribute_names.include?(name) || (!pf_framework_method?(name) && pf_argumentless_reader?(name))
          end

          # `id`, `attributes`, `save`…: wrapping these would break the record.
          def pf_framework_method?(name)
            ActiveRecord::Base.method_defined?(name) || ActiveRecord::Base.private_method_defined?(name)
          end

          def pf_argumentless_reader?(name)
            public_method_defined?(name) &&
              instance_method(name).parameters.none? { |type, _| REQUIRED_PARAMETERS.include?(type) }
          end

          def pf_define_virtual_reader(name)
            if attribute_names.include?(name)
              pf_define_virtual_attribute_reader(name)
            else
              pf_define_virtual_method_reader(name)
            end
          end

          # Attribute-API virtuals go through read_attribute, like columns.
          def pf_define_virtual_attribute_reader(name)
            pf_virtual_readers_module.define_method(name) do
              pf_mask_virtual_reads? ? read_attribute(name) : super()
            end
          end

          def pf_define_virtual_method_reader(name)
            pf_virtual_readers_module.define_method(name) do |*args, **options, &block|
              pf_guard_virtual_read(name, super(*args, **options, &block))
            end
          end

          # This class's own wrapper module (a subclass gets its own, so a
          # reader it overrides is wrapped where it is defined).
          def pf_virtual_readers_module
            return const_get(:MaskedVirtualReaders, false) if const_defined?(:MaskedVirtualReaders, false)

            const_set(:MaskedVirtualReaders, ReaderModule.new).tap { |readers| prepend(readers) }
          end
        end

        # Runs the block with this record's virtual readers unmasked. For the
        # model's own callbacks and validations, which otherwise compute with
        # the masked value. Scoped to this instance and restored when the block
        # ends, however it ends.
        #
        # The flag is kept beside the record (by identity, for the running
        # fiber: ExecutionState), not on it: a dup, clone or serialized copy made inside the
        # block is a different object and stays masked.
        def pf_without_virtual_masking
          unmasked = PermissionForge::ExecutionState.fetch(UNMASKED_KEY) { Set.new.compare_by_identity }
          added = unmasked.add?(self)
          yield
        ensure
          unmasked.delete(self) if added
        end

        # `methods:` names the current user may not read are dropped, the way
        # hidden columns are dropped from the attribute names, and listed as
        # hidden in the read's field.access event (one read with the columns).
        def serializable_hash(options = nil)
          PermissionForge::Audit::FieldAccess.read(self, self.class.name, record: self) do
            super(pf_without_hidden_virtual_methods(options))
          end
        end

        private

        def pf_mask_virtual_reads?
          return false if PermissionForge::ExecutionState[UNMASKED_KEY]&.include?(self)

          PermissionForge.configuration.mask_virtual_attributes_for?(self.class.name)
        end

        # What a wrapped reader returns for `raw`: the raw value, its mask, or
        # the hidden value.
        def pf_guard_virtual_read(name, raw)
          return raw unless pf_mask_virtual_reads?
          return pf_guard_unmaskable_read(name, raw) unless pf_maskable?(raw)

          include_field, value = pf_guard(name, raw)
          include_field ? value : PermissionForge.configuration.hidden_attribute_value
        end

        # Passed or hidden, never masked. The guard decides on a probe, so the
        # value itself is never stringified, and the read passes only when the
        # probe comes back untouched from a field that is not Masked. Masked
        # is read from the field's entry, not from what the mask strategy
        # returned: a custom strategy may hand its input back unchanged.
        def pf_guard_unmaskable_read(name, raw)
          include_field, value = pf_guard(name, PROBE)
          passed = include_field && value.equal?(PROBE) && !pf_masked_field?(name)
          passed ? raw : PermissionForge.configuration.hidden_attribute_value
        end

        # Truthy when the current user's entry for `name` is Masked, the test
        # AttributeAccessGuard applies once it knows the field is readable.
        def pf_masked_field?(name)
          field = pf_current_field_permissions(name)
          field && field[:mask_access]
        end

        def pf_maskable?(raw)
          raw.nil? || MASKABLE_TYPES.any? { |type| raw.is_a?(type) }
        end

        def pf_without_hidden_virtual_methods(options)
          methods = options && options[:methods]
          return options unless methods && pf_omit_hidden_virtual_methods?

          hidden, shown = Array(methods).partition { |name| pf_hidden_virtual_method?(name) }
          PermissionForge::Audit::FieldAccess.omitted(self, self.class.name.to_sym, hidden, pf_guarded_user) unless hidden.empty?
          options.merge(methods: shown)
        end

        def pf_hidden_virtual_method?(name)
          self.class.pf_masked_virtual_readers.include?(name.to_s) && pf_hidden_attribute?(name)
        end

        def pf_omit_hidden_virtual_methods?
          pf_mask_virtual_reads? && (pf_guarded_user || pf_hide_without_user?) &&
            PermissionForge.configuration.omit_hidden_in_attributes_hash
        end
      end
    end
  end
end
