# frozen_string_literal: true

module PermissionForge
  module Admin
    # Batched edits to one Permission Set (set header, resource CRUD/scope
    # flags, field levels, new fields, action toggles, new actions) as
    # submitted by the editor forms.
    #
    # Computes the list of real changes — after the same cascades the UI
    # shows (Read off => Edit/Delete/View All/Modify All off and Editable
    # fields downgraded; Edit off => Modify All off and Editable fields
    # downgraded) — and applies them in one transaction. Muting sets have
    # inverted semantics, so no cascades or dependencies apply to them.
    #
    # Params shape (all optional):
    #   set:        { name:, description:, is_active:, permission_set_group_id: }
    #   resources:  { "<id>" => { read_access: "1", ..., label:, description: } }
    #   fields:     { "<field id>" => { level: "masked", mask_strategy:, label:, description:, is_active: } }
    #   new_fields: { "<resource id>" => { "<column>" => { level: } } }
    #   actions:    { "<action id>" => { is_permitted: "1" } }
    #   bulk:       { resource_id:, keys: [...], level: }
    #   new_actions:  { "<resource id>" => { "<key>" => { is_permitted: "1" } } }
    #   bulk_actions: { resource_id:, is_permitted: "1" } — every discovered action without a row
    class ChangeSet
      # Collaborators, in evaluation order: later parts see earlier parts'
      # in-memory edits (field levels depend on the resource's new Edit flag).
      PARTS = [
        ChangeSetParts::SetAttrs,
        ChangeSetParts::ResourceFlags,
        ChangeSetParts::FieldLevels,
        ChangeSetParts::NewFields,
        ChangeSetParts::Actions,
        ChangeSetParts::NewActions
      ].freeze

      # kind: :set_attr | :resource_flag | :resource_text | :field_level | :field_attr | :new_field | :action |
      #       :new_action
      Change = Struct.new(:kind, :record, :attribute, :from, :to, :cascaded, :resource, keyword_init: true) do
        # Blank-ish values (nil, "") are equal; false is a real value.
        def unchanged?
          from == to || (from.blank? && to.blank? && from != false && to != false)
        end

        # Captures the record's current value as `from` and assigns `to`.
        # Returns self, or nil (nothing assigned) when effectively unchanged.
        def assign
          self.from = record.public_send(attribute)
          return if unchanged?

          record.public_send("#{attribute}=", to)
          self
        end
      end

      class Invalid < StandardError
        attr_reader :record

        def initialize(record)
          @record = record
          super(record.errors.full_messages.to_sentence)
        end
      end

      attr_reader :permission_set

      # @param catalog [ControllerCatalog, nil] the app's controller actions,
      #   for new_actions; built on first use when nil
      def initialize(permission_set:, params:, sensitive: SensitiveColumns.new, catalog: nil)
        @permission_set = permission_set
        @context = ChangeSetParts::Context.new(permission_set: permission_set, params: normalize(params),
                                               sensitive: sensitive, catalog: catalog)
      end

      def changes
        @changes ||= PARTS.flat_map { |part| part.new(@context).call }
      end

      def empty?
        changes.empty?
      end

      # Saves every pending record, all or nothing, under one audit
      # correlation id. Its own savepoint (requires_new) rolls back the saves
      # before a failing one — and their audit events — also when the caller's
      # transaction rescues Invalid and goes on to commit.
      #
      # @return [Array<Change>]
      # @raise [Invalid] a record failed validation; nothing was saved
      def apply!
        PermissionForge::Audit.correlate do
          ActiveRecord::Base.transaction(requires_new: true) do
            pending_records.each { |record| save!(record) }
          end
        end
        changes
      end

      private

      # Anything but a Hash of sections (a String, an Array) changes nothing.
      def normalize(params)
        hash = if params.respond_to?(:to_unsafe_h) then params.to_unsafe_h
               elsif params.is_a?(Hash) then params
               else {}
               end
        hash.deep_stringify_keys
      end

      def save!(record)
        raise Invalid, record unless record.save
      end

      # Records with assigned-but-unsaved attributes, in dependency order.
      def pending_records
        changes.map(&:record).uniq.select { |record| pending?(record) }
      end

      def pending?(record)
        record.new_record? || record.changed?
      end
    end
  end
end
