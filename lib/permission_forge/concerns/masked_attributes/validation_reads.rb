# frozen_string_literal: true

module PermissionForge
  module Concerns
    module MaskedAttributes
      # Validations judge the stored value; what they report shows what the
      # current user reads.
      #
      # A hidden or masked value would fail a presence or format check the
      # stored value passes (nobody signed in under :hide, a user who reads
      # `s***@acme.com` or nothing) and pass a uniqueness check against the
      # mask. So while the validators run (run_validations!), the attribute
      # Rails reads for a validation (read_attribute_for_validation) — that
      # one attribute, nothing else of the record — reads as stored: a derived
      # reader that reads other columns sees them masked, as always.
      #
      # Rails puts the value it validated into the error (value:, which
      # errors.details returns and %{value} interpolates). When the
      # validators are done, every error's value is replaced with what the
      # current user's getter returns, or removed when the user may not read
      # the attribute. A message rendered later reads the getter
      # (read_attribute_for_validation outside the validators), so %{value}
      # in a custom or i18n message shows the masked value or nothing.
      #
      # A Rails EachValidator reads the attribute through
      # read_attribute_for_validation and then, in numericality, again with
      # read_attribute (prepare_value_for_validation). So while an
      # EachValidator judges this record (EachValidatorWindow), the attribute
      # it last read for a validation stays readable as stored until the
      # validator is done; anything else — another validator, a custom
      # `validate` block — reads masked.
      #
      # @api private
      module ValidationReads
        # ExecutionState slots (fiber, by record identity): the records whose
        # validators are running, and the attribute each is reading for one.
        VALIDATING_KEY = :pf_validating_records
        READS_KEY = :pf_validation_reads
        # The records an EachValidator is judging right now.
        WINDOWS_KEY = :pf_validator_windows

        # Prepended to ActiveModel::EachValidator: keeps the attribute it
        # read for a validation readable as stored until it is done.
        module EachValidatorWindow
          def validate(record)
            return super unless record.is_a?(MaskedAttributes)

            ValidationReads.within_validator(record) { super }
          end
        end

        # @api private
        def self.within_validator(record)
          windows = PermissionForge::ExecutionState.fetch(WINDOWS_KEY) { Set.new.compare_by_identity }
          added = windows.add?(record)
          yield
        ensure
          if added
            windows.delete(record)
            PermissionForge::ExecutionState[READS_KEY]&.delete(record)
          end
        end

        def read_attribute_for_validation(name)
          window = pf_validator_window?
          return super unless pf_validation_read_open?(window)

          column = pf_validation_column(name)
          pf_reading_for_validation(column || name.to_s, keep: window) do
            column || !VirtualReaders.masked?(self.class, name) ? super : pf_without_virtual_masking { super }
          end
        end

        private

        def run_validations!
          validating = PermissionForge::ExecutionState.fetch(VALIDATING_KEY) { Set.new.compare_by_identity }
          added = validating.add?(self)
          super
        ensure
          validating&.delete(self) if added
          pf_mask_error_values
        end

        def pf_validating?
          PermissionForge::ExecutionState[VALIDATING_KEY]&.include?(self) || false
        end

        # Validating, and no other validation read in progress — or inside an
        # EachValidator, whose next read replaces the last.
        def pf_validation_read_open?(window)
          pf_validating? && (window || !pf_validation_read)
        end

        # Marks `attribute` as read as stored for the block; inside an
        # EachValidator (keep) it stays marked until the validator is done.
        def pf_reading_for_validation(attribute, keep:)
          reads = PermissionForge::ExecutionState.fetch(READS_KEY) { {}.compare_by_identity }
          reads[self] = attribute
          yield
        ensure
          reads&.delete(self) unless keep
        end

        def pf_validator_window?
          PermissionForge::ExecutionState[WINDOWS_KEY]&.include?(self) || false
        end

        # The attribute a validator is reading on this record, or nil.
        def pf_validation_read
          PermissionForge::ExecutionState[READS_KEY]&.[](self)
        end

        # The column an attribute name reads (an alias as the attribute at
        # the end of its chain), or nil for a method.
        def pf_validation_column(name)
          name = name.to_s
          target = self.class.attribute_aliases[name]
          name = pf_alias_end(target) if target
          name if self.class.attribute_names.include?(name)
        end

        def pf_mask_error_values
          errors.objects.each do |error|
            options = error.options
            next unless options.key?(:value) && error.attribute != :base

            include_field, value = pf_error_value(error.attribute)
            include_field ? options[:value] = value : options.delete(:value)
          end
        end

        # [include?, value]: what the current user reads for the attribute,
        # as a debugging read (no field.access decision). The primary key is
        # never masked. Anything that fails leaves no value.
        def pf_error_value(attribute)
          column = pf_validation_column(attribute)
          pf_while_inspecting do
            if column
              column == self.class.primary_key ? [true, _read_attribute(column)] : pf_guard(column, _read_attribute(column))
            else
              respond_to?(attribute) ? [true, public_send(attribute)] : [false, nil]
            end
          end
        rescue StandardError
          [false, nil]
        end
      end
    end
  end
end

ActiveModel::EachValidator.prepend(PermissionForge::Concerns::MaskedAttributes::ValidationReads::EachValidatorWindow)
