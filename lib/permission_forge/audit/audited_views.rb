# frozen_string_literal: true

module PermissionForge
  module Audit
    # The read-only admin pages that leave a trace: who looked at someone's
    # effective access, who read or exported the audit trail. One registry,
    # keyed by "controller_path#action"; the base controllers record the
    # first entry that applies after a successful (2xx) response — the
    # controllers themselves are not touched.
    #
    # Adding a page is one call:
    #
    #   AuditedViews.register('permission_forge/audit_events#index', 'audit.viewed',
    #                         only_if: ->(c) { c.request.format.html? },
    #                         payload: ->(c) { { data: { 'filters' => c.params.to_unsafe_h.slice('from', 'to') } } })
    #
    # `only_if` (optional) decides whether the entry applies to the request;
    # `payload` (optional) returns the keys passed to Audit.record (record:,
    # subject_user_id:, permission_set:, data: …). Actor, source, request id
    # and IP come from the request's audit context.
    #
    # @api private
    module AuditedViews
      View = Struct.new(:event, :only_if, :payload, keyword_init: true) do
        def applies?(controller)
          only_if.nil? || only_if.call(controller) ? true : false
        end

        def payload_for(controller)
          payload ? payload.call(controller) : {}
        end
      end

      @entries = {}

      class << self
        # @param key [String] "controller_path#action", e.g. 'permission_forge/people#show'
        # @param event [String] an admin, change or system event of the catalogue
        # @param only_if [#call, nil] lambda(controller) → whether the entry applies
        # @param payload [#call, nil] lambda(controller) → Hash for Audit.record
        # @raise [EventCatalog::UnknownEventError, ArgumentError]
        def register(key, event, only_if: nil, payload: nil)
          entry = EventCatalog.fetch(event)
          raise ArgumentError, "#{event} is an access event: views record admin events" if entry.runtime?

          (@entries[key.to_s] ||= []) << View.new(event: entry.name, only_if: only_if, payload: payload)
        end

        # Removes every entry of a key, or only those of one event.
        def unregister(key, event = nil)
          views = @entries[key.to_s]
          return unless views

          event ? views.reject! { |view| view.event == event } : views.clear
          @entries.delete(key.to_s) if views.empty?
        end

        # @return [Hash{String => Array<View>}]
        def entries
          @entries.transform_values(&:dup)
        end

        # @return [Array<View>]
        def entries_for(key)
          Array(@entries[key.to_s]).dup
        end

        # @return [View, nil] the first entry that applies to the request
        def match(controller)
          views = @entries["#{controller.controller_path}##{controller.action_name}"]
          views&.find { |view| view.applies?(controller) }
        end

        # Records the view when the response succeeded and an entry applies.
        # A HEAD request shows nothing and is not recorded.
        #
        # @return [AuditEvent, nil]
        def record(controller)
          return if controller.request.head? || !controller.response.successful?

          view = match(controller)
          Audit.record(view.event, **view.payload_for(controller)) if view
        end
      end

      # Shared pieces of the built-in entries. What was shown is decided by
      # the response (its media type), not by what the client asked for: an
      # Accept header can negotiate a CSV without a .csv in the path.
      module Requests
        AUDIT_FILTERS = %w[who type days sort].freeze
        LOG_FILTERS = %w[from to event category actor_type actor_id subject_user_id permission_set correlation_id
                         record_type record_id record_uuid].freeze
        API_FILTERS = %w[from to event category actor_type actor_id subject_user_id permission_set record_type record_id
                         record_uuid correlation_id page per_page].freeze
        VALUE_LIMIT = 255

        module_function

        def csv?(controller)
          controller.response.media_type == Mime[:csv].to_s
        end

        # 'csv' / 'json' for a file the response handed over, nil for a page.
        def export_format(controller)
          { Mime[:csv].to_s => 'csv', Mime[:json].to_s => 'json' }[controller.response.media_type]
        end

        def export?(controller)
          !export_format(controller).nil?
        end

        def tab?(controller, tab)
          !csv?(controller) && controller.params[:tab] == tab
        end

        # A parameter as a String: a scalar, or the first scalar of an
        # array (`?explain_user_id[]=7` — what `find_by(id: [...])` uses),
        # capped; nil for anything else.
        def scalar(value)
          value = value.first if value.is_a?(Array)
          value.to_s[0, VALUE_LIMIT] if value.is_a?(String) || value.is_a?(Numeric)
        end

        def id_param(controller, key)
          scalar(controller.params[key])
        end

        def person(controller, data = {})
          { subject_user_id: id_param(controller, :id), data: data }
        end

        def permission_set(controller, data = {})
          { record: find_set(id_param(controller, :id)), data: data }
        end

        def find_set(id)
          PermissionForge::PermissionSet.find_by(id: id) if id
        end

        def filters(controller, names)
          names.to_h { |name| [name, scalar(controller.params[name])] }.compact_blank
        end

        def audit_filters(controller)
          filters(controller, AUDIT_FILTERS)
        end
      end

      requests = Requests

      # A person's page: effective access tab, audit tab, the CSV of their changes.
      register('permission_forge/people#show', 'audit.exported',
               only_if: requests.method(:csv?),
               payload: ->(controller) { requests.person(controller, 'scope' => 'person', 'format' => 'csv') })
      register('permission_forge/people#show', 'admin.effective_access_viewed',
               only_if: ->(controller) { requests.tab?(controller, 'effective') },
               payload: ->(controller) { requests.person(controller, 'scope' => 'person') })
      register('permission_forge/people#show', 'audit.viewed',
               only_if: ->(controller) { requests.tab?(controller, 'audit') },
               payload: ->(controller) { requests.person(controller, 'scope' => 'person') })

      # A Permission Set's audit tab and its CSV export.
      register('permission_forge/permission_sets#show', 'audit.exported',
               only_if: requests.method(:csv?),
               payload: lambda { |controller|
                 requests.permission_set(controller, 'scope' => 'permission_set', 'format' => 'csv', 'filters' => requests.audit_filters(controller))
               })
      register('permission_forge/permission_sets#show', 'audit.viewed',
               only_if: ->(controller) { requests.tab?(controller, 'audit') },
               payload: lambda { |controller|
                 requests.permission_set(controller, 'scope' => 'permission_set', 'filters' => requests.audit_filters(controller))
               })

      # The field drawer's "explain for a person": that person's effective access to the field.
      # Same test as the controller's (`params[:explain_user_id].present?`), so whatever it explains is recorded.
      register('permission_forge/resource_fields#show', 'admin.effective_access_viewed',
               only_if: ->(controller) { controller.params[:explain_user_id].present? },
               payload: lambda { |controller|
                 { subject_user_id: requests.id_param(controller, :explain_user_id),
                   permission_set: requests.find_set(requests.id_param(controller, :permission_set_id)),
                   data: { 'scope' => 'field', 'resource' => controller.params[:resource_model].to_s, 'field' => controller.params[:key].to_s } }
               })

      # The audit log pages (AuditEventsController): the filtered list, its
      # CSV / JSON export, one event, and the "who holds what" export.
      register('permission_forge/audit_events#index', 'audit.exported',
               only_if: requests.method(:export?),
               payload: lambda { |controller|
                 { data: { 'scope' => 'log', 'format' => requests.export_format(controller),
                           'filters' => requests.filters(controller, Requests::LOG_FILTERS) } }
               })
      register('permission_forge/audit_events#index', 'audit.viewed',
               payload: lambda { |controller|
                 { data: { 'scope' => 'log', 'filters' => requests.filters(controller, Requests::LOG_FILTERS + %w[views page]) } }
               })
      register('permission_forge/audit_events#show', 'audit.viewed',
               payload: ->(controller) { { data: { 'scope' => 'event', 'identifier' => requests.id_param(controller, :id) } } })
      register('permission_forge/audit_events#holdings', 'audit.exported',
               payload: ->(controller) { { data: { 'scope' => 'holdings', 'format' => requests.export_format(controller) } } })

      # The JSON API's audit log (Api::AuditEventsController): a page of events, or one.
      register('permission_forge/api/audit_events#index', 'audit.viewed',
               payload: ->(controller) { { data: { 'scope' => 'api', 'filters' => requests.filters(controller, Requests::API_FILTERS) } } })
      register('permission_forge/api/audit_events#show', 'audit.viewed',
               payload: ->(controller) { { data: { 'scope' => 'api', 'identifier' => requests.id_param(controller, :identifier) } } })
    end
  end
end
