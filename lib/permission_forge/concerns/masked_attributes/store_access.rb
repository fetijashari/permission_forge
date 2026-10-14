# frozen_string_literal: true

module PermissionForge
  module Concerns
    module MaskedAttributes
      # Store accessors (`store :settings, accessors: [:theme]`,
      # `store_accessor`) reach the store column through its public getter —
      # the masked one. Left alone, a hidden or masked store column makes Rails
      # see nil (or the mask) where it expects the stored hash: depending on
      # the Rails version the read raises, or Rails replaces the column with an
      # empty hash in memory and a later save wipes the stored data.
      #
      #   - Reading a key of a store column the user may not read in full
      #     returns the hidden value and never touches the column.
      #   - Writing a key works on the real stored hash, so the other keys
      #     survive. The accessors and the column getter still return nothing
      #     readable afterwards.
      #
      # Only stores whose getter this concern masks are affected (a column, or
      # a wrapped virtual reader while virtual masking is on); any other store
      # is left to Rails.
      #
      # @api private
      module StoreAccess
        # Fiber-local ExecutionState slot: map (by identity) of record => the
        # store column an accessor is writing. Kept beside the record, like
        # the virtual-masking escape hatch, so a copy made during the write
        # or another thread holding the record never reads the column raw.
        RAW_STORE_KEY = :pf_raw_store_columns

        private

        def read_store_attribute(store_attribute, key)
          return super if pf_store_column_readable?(store_attribute) || pf_store_column_unloaded?(store_attribute)

          PermissionForge.configuration.hidden_attribute_value
        end

        def write_store_attribute(store_attribute, key, value)
          pf_with_raw_store_column(store_attribute) { super }
        end

        # The attribute Rails reads the store through: a store may be declared
        # on an alias_attribute name.
        def pf_store_column_name(store_attribute)
          name = store_attribute.to_s
          self.class.attribute_aliases[name] || name
        end

        # Readable in full for the current user. Asked of the guard with a
        # probe rather than by comparing stored values: a store that is nil
        # (a NULL json column, a new record) must not look "readable".
        def pf_store_column_readable?(store_attribute)
          name = pf_store_column_name(store_attribute)
          return true unless pf_masked_reader?(name)

          include_field, value = pf_guard(name, VirtualReaders::PROBE)
          include_field && value.equal?(VirtualReaders::PROBE)
        end

        # A store column the record was loaded without (`select(:id)`). Rails
        # raises ActiveModel::MissingAttributeError when an accessor reads or
        # writes one of its keys; hidden or not, it is left to do so.
        def pf_store_column_unloaded?(store_attribute)
          name = pf_store_column_name(store_attribute)
          self.class.has_attribute?(name) && !has_attribute?(name)
        end

        # Whether the reader of `name` is one this concern masks: the one Rails
        # is about to call for a store, or the target of an alias (AliasAccess).
        def pf_masked_reader?(name)
          pf_masked_column?(name) || (pf_mask_virtual_reads? && self.class.pf_virtual_reader_masked?(name))
        end

        # A column whose getter is masked and whose setter is guarded.
        def pf_masked_column?(name)
          klass = self.class
          klass.const_defined?(:MaskedAttributeReaders) && klass::MaskedAttributeReaders.method_defined?(name)
        end

        # Inside the block this record's getter for the store column returns
        # the stored value (see MaskedAttributes#read_attribute). Only that
        # column, only this record on this fiber, and restored when
        # the block ends.
        def pf_with_raw_store_column(store_attribute)
          windows = PermissionForge::ExecutionState.fetch(RAW_STORE_KEY) { {}.compare_by_identity }
          previous = windows[self]
          windows[self] = pf_store_column_name(store_attribute)
          yield
        ensure
          previous ? windows[self] = previous : windows.delete(self)
        end

        def pf_raw_store_column?(name)
          PermissionForge::ExecutionState[RAW_STORE_KEY]&.[](self) == name
        end
      end
    end
  end
end
