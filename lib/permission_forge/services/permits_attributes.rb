module PermissionForge
  module Services
    # Filters permitted params by the current user's field-level EDIT permissions.
    #
    # A key is kept when the user may edit that field on the resource, whatever
    # its value: a Hash or an Array is a value like any other (a json column),
    # never a payload to look into. A key the user may not edit is dropped,
    # whatever its value (fail closed).
    #
    # The one exception is a nested payload: `<assoc>_attributes` for an
    # association the model accepts nested attributes for. It is filtered
    # record by record against the ASSOCIATION MODEL's own resource entry — an
    # Array per element, Rails' index Hash per value, a has_one / belongs_to
    # Hash as one record; an element that is not a record is dropped. A
    # record keeps its `id` only when it names a row the user may reach
    # ({NestedRecords}: inside the child model's `permission_scoped`, or the
    # child has no row rules to ask); a denied record is dropped whole. A
    # record keeps its `_destroy` only when the user may delete the model
    # the payload is filtered for (its entry's `delete_access`; Rails would
    # otherwise destroy the row on the strength of an edit grant). When
    # the user's hash has no entry for that model the payload is dropped;
    # config.nested_attributes_parent_fallback = true filters it against the
    # parent's fields and delete access instead (the id check still applies).
    #
    # Non-mutating: the caller's params object is never modified; a new plain Hash
    # is returned.
    #
    # The keys that were dropped are published as params.filtered (when it is
    # stored or heard; nothing is collected otherwise): their paths —
    # `secret`, `supplier_attributes.secret`, `lines_attributes.*.price`,
    # `lines_attributes.*` for an element that is no record — never their
    # values. Without a user every key is dropped (reason nil_user).
    #
    # With `report: true` the call answers a {Result} instead: the same
    # filtered hash plus the paths of the dropped keys, so a controller can
    # tell the user what was not saved (the default return is unchanged).
    #
    # @example
    #   filtered = PermitsAttributes.call(resource: customer, permitted_params: params)
    # @example Telling the user what was not saved
    #   result = PermitsAttributes.call(resource: customer, permitted_params: params, report: true)
    #   customer.update(result.params)
    #   flash[:alert] = "Not saved: #{result.dropped_fields.join(', ')}" if result.dropped?
    #
    # @api public
    class PermitsAttributes
      EVENT = 'params.filtered'.freeze
      NESTED_SUFFIX = '_attributes'.freeze
      # The path segment of a record inside a collection payload.
      EACH = '*'.freeze
      # The keys of a nested record that name it rather than set a field.
      RECORD_KEYS = %w[id].freeze
      # The key of a nested record that asks for its destruction.
      DESTROY_KEY = '_destroy'.freeze

      # Filters incoming params by the user's field-level edit access (does not mutate them).
      # @param resource [ActiveRecord::Base, Class] the record or model class whose Resource rows decide
      # @param permitted_params [Hash]
      # @param report [Boolean] answer a {Result} (filtered params and dropped paths)
      # @return [Hash, Result] the filtered hash; a {Result} with `report: true`
      def self.call(resource:, permitted_params:, report: false)
        new(resource: resource, permitted_params: permitted_params, report: report).call
      end

      def initialize(resource:, permitted_params:, report: false)
        @user = PermissionForge.current_user
        @resource = resource
        @permitted_params = permitted_params
        @report = report
      end

      # @return [Hash, Result] a new hash holding only the fields the user may
      #   edit; with `report: true`, a {Result} holding it and the dropped paths
      def call
        filtered = filter
        @report ? Result.new(params: filtered, dropped: (@dropped || []).uniq) : filtered
      end

      private

      def filter
        return drop_everything if resource_class.nil? || @user.blank?
        return {} if @permitted_params.blank?

        report_dropped('field_access') { filter_for(resource_class, @permitted_params) }
      end

      # Every key is dropped: nobody is signed in (published as nil_user), or
      # there is no model to filter for (reported only: params.filtered
      # names the model).
      def drop_everything
        if @permitted_params.present? && (@report || PermissionForge::Audit.instrument?(EVENT))
          report_dropped('nil_user') { @permitted_params.each_pair { |key, _| dropped(key) } }
        end
        {}
      end

      # Runs the filter, collecting the dropped paths in @dropped only when
      # the caller asked for a report or params.filtered is stored or heard,
      # and publishes them to the latter.
      def report_dropped(reason)
        instrumented = !resource_class.nil? && PermissionForge::Audit.instrument?(EVENT)
        return yield unless instrumented || @report

        @dropped = []
        @path = []
        result = yield
        publish_dropped(reason) if instrumented && !@dropped.empty?
        result
      end

      def publish_dropped(reason)
        dropped = @dropped.uniq
        record = @resource.is_a?(Class) ? nil : @resource
        PermissionForge::Audit.instrument(EVENT) do
          reference = record ? { record: record } : { record_type: PermissionForge::Audit::Runtime.record_type(resource_class) }
          reference.merge(subject_user_id: PermissionForge::Audit::Runtime.user_id(@user),
                          data: { 'model' => resource_class.name, 'reason' => reason, 'dropped' => dropped },
                          objects: { user: @user, record: record })
        end
      end

      # Records the dropped key's path, when dropped keys are collected. Nil,
      # so that a dropped element leaves nothing in a filter_map.
      def dropped(key)
        @dropped&.push((@path + [key.to_s]).join('.'))
        nil
      end

      def within(segment)
        return yield unless @dropped

        @path.push(segment.to_s)
        begin
          yield
        ensure
          @path.pop
        end
      end

      def resource_class
        return nil if @resource.nil?

        @resource.is_a?(Class) ? @resource : @resource.class
      end

      # A NEW hash with the keys editable on `klass`, each nested payload
      # filtered for its own model. Everything else is dropped (fail closed).
      def filter_for(klass, params, record: false)
        fields = editable_fields_for(klass)
        result = {}

        params.each_pair do |key, value|
          if (association = nested_association(klass, key))
            filtered = within(key) { filter_nested(klass, association, value) }
            filtered.nil? ? dropped(key) : result[key] = filtered
          elsif fields.key?(key.to_sym) || (record && record_key?(klass, key))
            result[key] = value
          else
            dropped(key)
          end
        end

        result
      end

      # A key of a nested record that names it rather than sets a field —
      # or its `_destroy`, when the user may delete records of `klass`.
      def record_key?(klass, key)
        name = key.to_s
        RECORD_KEYS.include?(name) || (name == DESTROY_KEY && deletable?(klass))
      end

      # Whether the user may delete records of `klass`: the delete_access of
      # the entry the class answers to (ResourceChain.grants?). Once per
      # class and call.
      def deletable?(klass)
        @deletable ||= {}
        @deletable.fetch(klass) do
          @deletable[klass] = @user.respond_to?(:permissions_hash) &&
                              PermissionForge::ResourceChain.grants?(@user, resource_names(klass), :delete_access)
        end
      end

      # The association behind a `<assoc>_attributes` key, when `klass`
      # accepts nested attributes for it. Any other key is a field.
      def nested_association(klass, key)
        name = key.to_s
        return unless name.end_with?(NESTED_SUFFIX) && klass.respond_to?(:nested_attributes_options)

        assoc_name = name.delete_suffix(NESTED_SUFFIX).to_sym
        klass.reflect_on_association(assoc_name) if klass.nested_attributes_options.key?(assoc_name)
      end

      # The payload filtered for the model it is for, minus the records whose
      # id names a row the child's row rules deny (NestedRecords) — or nil,
      # the key dropped as a whole: no entry for that model, not a payload,
      # or its one record denied.
      def filter_nested(parent_klass, association, value)
        child = association_class(association)
        target = nested_target(parent_klass, child)
        return unless target

        filtered = filter_payload(target, association, value)
        NestedRecords.new(child, collection: association.collection?).admit(filtered) { dropped(EACH) } unless filtered.nil?
      end

      # The model a nested payload is filtered for: the association's own,
      # when the user's hash has an entry for it; the parent, only under
      # config.nested_attributes_parent_fallback (a key editable on the
      # parent then admits the same key on a child the user was never
      # granted); nothing otherwise.
      def nested_target(parent_klass, child)
        return child if child && configured_resource?(child)

        parent_klass if PermissionForge.configuration.nested_attributes_parent_fallback
      end

      # nil for a polymorphic association (no one model) or one whose model
      # does not load: such a payload is dropped.
      def association_class(association)
        association.klass unless association.polymorphic?
      rescue NameError
        nil
      end

      def filter_payload(target, association, value)
        return filter_record(target, value) unless association.collection?
        return filter_each(target, value) if value.is_a?(Array)
        return unless each_pair?(value)

        # As Rails reads a collection Hash: one record when it has an id,
        # otherwise the index form, whose values are the records.
        record_with_id?(value) ? within(EACH) { filter_record(target, value) } : filter_indexed(target, value)
      end

      # One record (a has_one / belongs_to payload, or one of a collection),
      # with one id (NestedRecords.with_one_id); nil when it is no record or
      # names two ids.
      def filter_record(target, value)
        NestedRecords.with_one_id(filter_for(target, value, record: true)) if each_pair?(value)
      end

      def filter_each(target, records)
        records.filter_map do |record|
          filtered = within(EACH) { filter_record(target, record) }
          filtered.nil? ? dropped(EACH) : filtered
        end
      end

      def filter_indexed(target, records)
        result = {}
        records.each_pair do |index, record|
          filtered = within(EACH) { filter_record(target, record) }
          filtered.nil? ? dropped(EACH) : result[index] = filtered
        end
        result
      end

      def record_with_id?(value)
        value.key?('id') || value.key?(:id)
      end

      # The Resource names a model answers to: its own and its STI
      # ancestors' (ResourceChain).
      def resource_names(klass)
        PermissionForge::ResourceChain.names(klass)
      end

      def configured_resource?(klass)
        @user.respond_to?(:permissions_hash) && PermissionForge::ResourceChain.entries(@user, resource_names(klass)).any?
      end

      # A key is editable where the field is readable AND editable: the hash
      # the builder writes says so already (FieldPermissionMerger counts edit
      # only with read), but a hash another version cached may still say
      # `edit_access: true, read_access: false` — a field nobody may read is
      # not one they may write.
      def editable_fields_for(klass)
        return {} unless @user.respond_to?(:permissions_hash)

        PermissionForge::ResourceChain.fields(@user, resource_names(klass))
                                      .select { |_, access| access[:read_access] && access[:edit_access] }
      end

      def each_pair?(value)
        value.respond_to?(:each_pair)
      end
    end
  end
end
