# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Writes one audit event per create, update and destroy of a permission
    # record (PermissionForge::Audit.record) — from after_create, after_update
    # and after_destroy, inside the record's own transaction, so a change
    # whose event cannot be written rolls back under the default
    # `config.audit_change_failure_strategy = :raise`.
    #
    # What an event carries:
    #   create  — data["snapshot"]: every attribute of the new row
    #   update  — data["changes"]: saved_changes minus the bookkeeping columns
    #             (created_at, updated_at, created_by_id, updated_by_id); a
    #             save that changed nothing else writes no event. A model
    #             adds keys of its own through #audit_update_details (an
    #             assignment moved to another user: previous_subject_user_id)
    #   destroy — data["snapshot"]: every attribute of the deleted row
    # plus the record reference (#audit_reference): type, id, uuid, label, the
    # Permission Set, the subject user of an assignment or membership, and
    # the record's tenant. Everything written in one transaction shares a
    # correlation id (a cascade delete, a Review-and-save).
    #
    # A caller that means something more specific by a save renames and
    # enriches the row's own event instead of adding a second one:
    #
    #   assignment.audit_as('assignment.reviewed', data: { 'decision' => 'keep' }, reason: reason) do
    #     assignment.update!(reviewed_at: Time.current, reviewed_by_id: admin.id)
    #   end
    #
    # Paths that run no callbacks write no event: touch, update_column(s),
    # update_all, delete_all, delete, insert_all, upsert_all. The gem's own
    # code does not use them on these models; a test guards against new uses.
    #
    # Nothing is kept on the record outside a callback or an audit_as block:
    # it can still be marshalled, and its associations are left as they were.
    #
    # @api private
    module RecordsAuditEvents
      extend ActiveSupport::Concern

      BOOKKEEPING_COLUMNS = %w[created_at updated_at created_by_id updated_by_id].freeze
      VERBS = { create: 'created', update: 'updated', destroy: 'destroyed' }.freeze

      # Models whose events have their own names in the catalogue, by
      # model key (base_class.model_name.element). Every other model's events
      # are "<key>.created|updated|destroyed".
      EVENT_NAMES = {
        'permission_set_user' => { create: 'assignment.granted', update: 'assignment.changed', destroy: 'assignment.revoked' },
        'permission_set_group_user' => { create: 'group_membership.added', update: 'group_membership.changed',
                                         destroy: 'group_membership.removed' }
      }.freeze

      # The Permission Set an event about the record belongs to, by model key.
      # Groups and memberships belong to none. Associations are read through
      # #audit_associated: as loaded, else fetched in the record's own tenant.
      OWN_SET = ->(record) { record.audit_associated(:permission_set) }
      SET_OF_RESOURCE = ->(record) { record.audit_associated(:resource)&.audit_permission_set }
      PERMISSION_SET = {
        'permission_set' => ->(record) { record },
        'resource' => OWN_SET, 'permission_set_rule' => OWN_SET, 'permission_set_user' => OWN_SET,
        'resource_field' => SET_OF_RESOURCE, 'resource_action' => SET_OF_RESOURCE
      }.freeze

      # How the record is labelled, by model key; the default is its name.
      QUALIFIED_NAME = ->(record) { [record.audit_associated(:resource)&.name, record.name].compact.join('.') }
      PERSON_NAME = lambda { |record|
        user = record.audit_associated(:user)
        PermissionForge::Audit::Actor.label_for(user) if user
      }
      LABELS = {
        'resource_field' => QUALIFIED_NAME, 'resource_action' => QUALIFIED_NAME,
        'permission_set_user' => PERSON_NAME, 'permission_set_group_user' => PERSON_NAME
      }.freeze

      # The names #audit_as may give a model's own events, by model key and
      # action — a more specific name for the same row change, never another
      # model's event. Adding one is one entry.
      AUDIT_AS_RENAMES = {
        'permission_set_user' => { update: %w[assignment.reviewed] },
        'resource_field' => { update: %w[field.sensitive_acknowledged] }
      }.freeze

      # Keys of an event's data that the concern computes (#audit_as cannot set them).
      AUDIT_AS_COMPUTED_KEYS = %w[changes snapshot].freeze

      included do
        after_create :record_audit_event_for_create
        after_update :record_audit_event_for_update
        after_destroy :record_audit_event_for_destroy
      end

      class_methods do
        # @param action [Symbol] :create, :update or :destroy
        # @return [String] the catalogue name of the event
        def audit_event_name(action)
          action = action.to_sym
          EVENT_NAMES.dig(audit_model_key, action) || "#{audit_model_key}.#{VERBS.fetch(action)}"
        end

        # 'permission_set', 'resource_field', ... — also for a subclass.
        def audit_model_key
          base_class.model_name.element
        end
      end

      # Records this record's events inside the block under `event` instead
      # of their own name, with `data` added to theirs and `reason` on them —
      # only for the actions AUDIT_AS_RENAMES lists for the model and that
      # event (a review or an acknowledgement is an update); any other
      # action inside the block keeps its own event. Instance-scoped,
      # block-only, restored when the block ends or raises. Nothing is set
      # when the arguments are refused.
      #
      # @param event [String] a change event the model may be renamed to
      # @param data [Hash] event-specific keys; the computed 'changes' /
      #   'snapshot' cannot be replaced
      # @param reason [String, nil]
      # @return the value of the block
      # @raise [Audit::EventCatalog::UnknownEventError, ArgumentError]
      def audit_as(event, data: {}, reason: nil)
        override = audit_as_override(event, data, reason) # raises before anything is set
        previous = @pf_audit_as
        @pf_audit_as = override
        begin
          yield
        ensure
          @pf_audit_as = previous
        end
      end

      # The columns an event about this record carries (Audit::Recorder).
      #
      # @return [Hash] record_type, record_id, record_uuid, record_label,
      #   permission_set_id, permission_set_uuid, subject_user_id, tenant_id
      def audit_reference
        with_audit_lookups do
          set = audit_permission_set
          {
            record_type: self.class.base_class.name, record_id: id&.to_s, record_uuid: audit_uuid, record_label: audit_record_label,
            permission_set_id: set&.id, permission_set_uuid: set&.uuid,
            subject_user_id: audit_subject_user_id, tenant_id: audit_tenant_id
          }
        end
      end

      # Every attribute, JSON-ready.
      def audit_snapshot
        attributes.as_json
      end

      # saved_changes minus the bookkeeping columns, JSON-ready.
      def audit_changes = saved_changes.except(*BOOKKEEPING_COLUMNS).as_json

      # Whether the last save wrote a change event: SaveNotice asks it.
      def saved_audited_changes? = audit_changes.any?

      # Whether saving now would write one (a new record always does): the
      # admin saves a record only then (SaveNotice#pf_save_changed), so an
      # unchanged submit runs no commit callback and invalidates nobody's
      # cached permissions. Never asked by a callback: a second, unchanged
      # save in a transaction must not drop the first one's invalidation.
      def audited_changes_pending? = new_record? || changes_to_save.except(*BOOKKEEPING_COLUMNS).any?

      # The Permission Set an event about this record belongs to, if any.
      def audit_permission_set
        PERMISSION_SET[self.class.audit_model_key]&.call(self)
      end

      # A belongs_to target as loaded, else fetched in this record's tenant
      # and past every default scope — the ambient tenant may be another one
      # or none (acts_as_tenant then raises under require_tenant), and the
      # host's user model may hide the person behind a soft delete. What is
      # fetched is not written to the association (the record would then
      # answer with a hidden user, or with nothing for a row that is gone);
      # inside #audit_reference it is looked up once.
      #
      # @param name [Symbol] a belongs_to association
      # @return [ActiveRecord::Base, nil]
      def audit_associated(name)
        association = association(name)
        return association.target if association.loaded?
        return @pf_audit_lookups[name] if @pf_audit_lookups&.key?(name)

        id = self[association.reflection.foreign_key]
        found = id.nil? ? nil : audit_fetch(association.klass, id)
        @pf_audit_lookups[name] = found if @pf_audit_lookups
        found
      end

      private

      # The validated #audit_as state: the event, the actions it renames, the
      # data and the reason.
      def audit_as_override(event, data, reason)
        entry = PermissionForge::Audit::EventCatalog.fetch(event)
        raise ArgumentError, "#{entry.name} is a #{entry.category} event: audit_as takes a change event" unless entry.category == 'change'

        { event: entry.name, actions: audit_as_actions(entry.name), data: audit_as_data(data), reason: reason }
      end

      # The actions of this model that may be recorded as `name` (AUDIT_AS_RENAMES).
      def audit_as_actions(name)
        key = self.class.audit_model_key
        actions = AUDIT_AS_RENAMES.fetch(key, {}).select { |_, names| names.include?(name) }.keys
        raise ArgumentError, "#{key} events cannot be recorded as #{name}" if actions.empty?

        actions
      end

      def audit_as_data(data)
        data = data.as_json
        reserved = data.keys & AUDIT_AS_COMPUTED_KEYS
        raise ArgumentError, "audit_as data cannot set #{reserved.join(', ')}" if reserved.any?

        data
      end

      # Memoizes association lookups for the duration of the block only.
      def with_audit_lookups
        @pf_audit_lookups = {}
        yield
      ensure
        @pf_audit_lookups = nil
      end

      def audit_fetch(klass, id)
        scope = klass.respond_to?(:of_tenant) ? klass.of_tenant(audit_tenant_id) : klass.unscoped
        PermissionForge::Concerns::AutoPermissionScoping.internally_suspended { scope.find_by(klass.primary_key => id) }
      end

      def record_audit_event_for_create
        record_audit_event(:create, 'snapshot' => audit_snapshot)
      end

      def record_audit_event_for_update
        return unless saved_audited_changes?

        record_audit_event(:update, audit_update_details.merge('changes' => audit_changes))
      end

      # Event data a model adds to its update events (the computed 'changes' wins).
      def audit_update_details
        {}
      end

      def record_audit_event_for_destroy
        return unless audit_row_deleted?

        record_audit_event(:destroy, 'snapshot' => audit_snapshot)
      end

      # Rails runs after_destroy also when the DELETE hit no row — an instance
      # destroyed before, or already gone through a cascade. Nothing changed
      # then, and the event for the row was written when it did go. Rails
      # keeps the answer for its own commit callbacks (7.1 to 8.1).
      def audit_row_deleted?
        return true unless respond_to?(:_trigger_destroy_callback, true)

        send(:_trigger_destroy_callback) ? true : false
      end

      # The row's own event, or the one an enclosing audit_as block asked for.
      def record_audit_event(action, data)
        override = @pf_audit_as if @pf_audit_as&.fetch(:actions)&.include?(action)
        event = override ? override[:event] : self.class.audit_event_name(action)
        data = override[:data].merge(data) if override # the computed keys win
        PermissionForge::Audit.record(event, record: self, data: data, reason: override&.fetch(:reason))
      end

      def audit_uuid
        has_attribute?(:uuid) ? self[:uuid] : nil
      end

      def audit_record_label
        label = LABELS[self.class.audit_model_key]
        label ? label.call(self) : try(:name)
      end

      def audit_subject_user_id
        user_id&.to_s if respond_to?(:user_id)
      end

      def audit_tenant_id
        config = PermissionForge.configuration
        return unless config.tenant_enabled?

        column = config.resolved_tenant_column
        self[column] if has_attribute?(column)
      end
    end
  end
end
