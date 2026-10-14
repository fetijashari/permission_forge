# frozen_string_literal: true

module PermissionForge
  module Audit
    # field.access — one event per record read, listing the fields that were
    # hidden, masked, unconfigured or bypassed (no user), and the fields read
    # in the clear (`passed_fields`, with their count in `passed`).
    #
    # A read is the outermost guarded access to one record: a getter, `[]` /
    # `read_attribute`, `attributes`, `serializable_hash` (`as_json`,
    # `to_json`), a virtual or store reader. While it runs, every decision
    # AttributeAccessGuard makes about that record goes into one Frame, kept
    # in a fiber-local ExecutionState slot (never on the record), and the
    # event is published when the read returns. A read nested inside another record's
    # read (an association serialized with `include:`) gets its own frame and
    # event. Three getters called one after the other are three reads, so
    # three events: the gem cannot know when a view or serializer is done
    # with a record. FiltersResponseAttributes publishes one per hash it
    # filters.
    #
    # Nothing is collected unless the event is stored (config.audit_runtime_events
    # includes :field_read) or someone listens: the read then costs one
    # Audit::Gate check. When the legacy on_field_filtered hook is the only
    # listener and nothing is stored, no event is built either: each decision
    # goes straight to the hook (Direct), as before the audit event log. The frame records every decision, passed ones too —
    # the legacy on_field_filtered hook is called for each of them
    # (payload[:objects][:decisions]); the stored row keeps the field names
    # of each kind of decision (never a value). The names are gathered only
    # when the event is built.
    #
    # @api private
    module FieldAccess
      EVENT = 'field.access'
      # The ExecutionState slot of the read in progress (its Frame).
      KEY = :pf_audit_field_access

      # One AttributeAccessGuard decision. `hook` is false for a decision the
      # legacy on_field_filtered hook was never called for (an unconfigured
      # field in FiltersResponseAttributes, a response filtered without user).
      Decision = Struct.new(:resource_name, :field_name, :action, :user, :hook)

      LISTED = %i[hidden masked unconfigured bypassed].freeze

      ENTRY = EventCatalog.fetch(EVENT)
      # Asked on every guarded read.
      GATE = Gate.for(EVENT)

      # The decisions of one read.
      class Frame
        attr_reader :owner

        # @param owner [Object] what is read: a record, or the Hash a
        #   response filter works on
        # @param resource_name [String]
        # @param record [ActiveRecord::Base, nil] the record, when there is one
        # @param record_id [Object, nil] the id, when there is no record
        def initialize(owner, resource_name, record = nil, record_id = nil)
          @owner = owner
          @resource_name = resource_name.to_s
          @record = record
          @record_id = record_id
          @decisions = []
        end

        # @return [void]
        def add(resource_name, field_name, action, user, hook: true)
          return if Audit.emitting?

          @decisions << Decision.new(resource_name.is_a?(Symbol) ? resource_name.name : resource_name.to_s, field_name, action, user, hook)
        end

        # Publishes the read's event (nothing when no field was decided).
        def emit
          return if @decisions.empty?

          decisions = @decisions.freeze
          # the legacy hook alone needs only the decisions (Gate#direct_listeners)
          light = GATE.direct_listeners
          return Audit.emit_light(ENTRY, light, { event: EVENT, data: nil, objects: objects(decisions) }) if light

          Audit.instrument(EVENT) { payload(decisions) }
        end

        private

        def payload(decisions)
          user = decisions.first.user
          reference = @record ? { record: @record } : { record_type: @resource_name, record_id: @record_id }
          reference.merge(subject_user_id: Runtime.user_id(user), data: data(decisions), objects: objects(decisions))
        end

        def objects(decisions)
          { user: decisions.first.user, record: @record, decisions: decisions }
        end

        def data(decisions)
          lists = LISTED.to_h { |action| [action.to_s, []] }
          passed = []
          decisions.each { |decision| add_name(decision.action == :passed ? passed : lists[decision.action.to_s], decision) }
          { 'model' => @resource_name }.merge(lists).merge('passed' => passed.size, 'passed_fields' => passed)
        end

        def add_name(names, decision)
          name = decision.field_name.to_s
          names << name if names && !names.include?(name)
        end
      end

      # Where decisions go when the legacy on_field_filtered hook is the only
      # listener and nothing is stored (Gate#direct_listeners): straight to
      # the hook, one call per decision as before the audit event log — no
      # frame, no event. Re-entrancy guarded like any emission.
      module Direct
        def self.add(resource_name, field_name, action, user, hook: true)
          return unless hook

          listeners = GATE.direct_listeners
          Audit.emit_decision(listeners, resource_name, field_name, action, user) if listeners
        end
      end

      class << self
        # Runs the block as one read of `owner`, and publishes its event.
        # Yields the frame to record decisions in, or nil when nobody listens.
        # A read inside a read of the same owner joins it.
        #
        # @param owner [Object] the record (or Hash) being read
        # @param resource_name [String]
        # @param record [Object, nil] the record, for the event's reference
        # @param record_id [Object, nil] the id when there is no record
        # @return the block's value
        def read(owner, resource_name, record: nil, record_id: nil)
          return yield(nil) unless GATE.open?

          outer = ExecutionState[KEY]
          return yield(outer) if outer&.owner.equal?(owner)
          return yield(Audit.emitting? ? nil : Direct) if GATE.direct_listeners
          return yield(nil) unless Audit.instrument?(EVENT)

          frame = Frame.new(owner, resource_name, record, record_id)
          run(frame) { yield(frame) }
        end

        # Fields a serialization leaves out because they are hidden
        # (attribute_names_for_serialization): decided without the guard, so
        # the legacy hook was never called for them. They join the read of
        # `owner` in progress, if any.
        #
        # @return [void]
        def omitted(owner, resource_name, names, user)
          frame = ExecutionState[KEY]
          return unless frame&.owner.equal?(owner)

          names.each { |name| frame.add(resource_name, name, :hidden, user, hook: false) }
        end

        # A decision made outside any read (AttributeAccessGuard called by
        # the host app): it joins the read in progress, or is a read of its own.
        #
        # @return [void]
        def note(resource_name, field_name, action, user)
          return unless GATE.open?

          frame = ExecutionState[KEY]
          return frame.add(resource_name, field_name, action, user) if frame
          return Direct.add(resource_name, field_name, action, user) if GATE.direct_listeners && !Audit.emitting?
          return unless Audit.instrument?(EVENT)

          single = Frame.new(nil, resource_name)
          single.add(resource_name, field_name, action, user)
          single.emit
        end

        private

        # The frame is the read in progress while the block runs; the outer
        # read (or none) is put back before the event is published.
        def run(frame, &)
          result = ExecutionState.with(KEY, frame, &)
          frame.emit
          result
        end
      end
    end
  end
end
