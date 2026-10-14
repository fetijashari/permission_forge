# frozen_string_literal: true

module PermissionForge
  module Admin
    # What the field drawer (resource_fields/show) shows for one column of a
    # Resource, decided here so the template only lays it out: the level and
    # mask strategy in force, which notes apply, whether the recommendation
    # can be applied, and which person is being explained.
    #
    # Words stay in the template (I18n); this answers which note, not what it
    # says.
    #
    # @example
    #   detail = FieldDetail.new(resource: resource, row: rows.row('email'), rows: rows)
    #   detail.locked?               # => false
    #   detail.unconfigured_note     # => :not_configured
    #   detail.recommendation        # => :apply
    class FieldDetail
      DEFAULT_STRATEGY = 'full'
      CONTEXT_KEYS = %i[rules across people_count explain_people explain explain_user_id].freeze

      attr_reader :resource, :row, :rows, :rules, :across, :people_count, :explain, :explain_people

      # rows: the FieldRows the row came from (it knows the model).
      # explain: { user:, field: } for the person picked in "Explain for a person", else nil.
      def initialize(resource:, row:, rows:, configuration: PermissionForge.configuration, **context)
        @resource = resource
        @row = row
        @rows = rows
        @configuration = configuration
        unknown = context.keys - CONTEXT_KEYS
        raise ArgumentError, "unknown context: #{unknown.join(', ')}" if unknown.any?

        @rules = context.fetch(:rules, [])
        @across = context[:across]
        @people_count = context[:people_count]
        @explain_people = context.fetch(:explain_people, [])
        @explain = context[:explain]
        @explain_user_id = context[:explain_user_id].to_s
      end

      def permission_set = resource.permission_set
      def key = row.name
      def field = row.field
      def label = row.label
      def muting? = permission_set.is_muting
      def level = row.level

      # Locked when the field, its Resource or its Permission Set is (is_editable: false).
      def locked? = !EditableLock.locked_record(field, resource).nil?

      # The mask strategy the select starts on: the saved one, else the
      # recommended one for a sensitive column, else 'full'.
      def strategy
        field&.mask_strategy || row.match&.strategy || DEFAULT_STRATEGY
      end

      # Other columns that follow this one (`_id` → `_uuid`, `_cents` → base name).
      def variants
        @variants ||= @configuration.field_variants_for(key)
      end

      # The edit level needs edit access on the Resource, except in a muting set.
      def edit_disabled? = !muting? && !resource.edit_access

      def in_force? = row.in_force?

      # The note under the level control while no setting is in force, as the
      # suffix of a locale key under `resource_fields.show` — or nil.
      def unconfigured_note
        return nil if row.in_force?

        implicit = row.implicit_grant
        if row.configured?
          implicit ? :turned_off_implicit : :turned_off
        else
          implicit ? :not_configured_implicit : :not_configured
        end
      end

      # Setting the note links to.
      def unconfigured_setting
        row.implicit_grant ? 'extra_fields_default_access' : 'unconfigured_field_strategy'
      end

      # What happens to a field nobody set up (a key under `ui.unconfigured`).
      def unconfigured_behaviour = @configuration.unconfigured_field_strategy

      def sensitive? = row.sensitive?

      # The privacy recommendation banner: only for a sensitive field in a granting set.
      def recommendation_banner? = sensitive? && !muting?

      # :applied (already masked with the recommended strategy), :apply (offer
      # the button) or nil (locked: nothing to offer).
      def recommendation
        return :applied if level == 'masked' && strategy == row.match.strategy
        return nil if locked?

        :apply
      end

      def virtual? = row.virtual
      def declared? = row.declared
      def extra_fields_method = @configuration.extra_fields_method
      def model_masks_virtual? = rows.model&.masked_on_model?(key) || false

      # The person the explain select starts on.
      def explain_selected?(user) = @explain_user_id == user.id.to_s
    end
  end
end
