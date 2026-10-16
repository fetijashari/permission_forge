# frozen_string_literal: true

module PermissionForge
  module Api
    class PermissionSetsController < BaseController
      # The shapes an activation condition is taken in (JSON): `allowed_ips`
      # a String (commas, newlines or spaces between the entries) or an Array
      # of Strings, an hour an integer (or a String of digits), a session
      # flag a String; null clears. Anything else is a 422 keyed by the
      # attribute — strong parameters would drop an Array under a scalar key,
      # or an object, without a word, and a dropped condition is a set that
      # applies from anywhere (field test round 6, d-api).
      CONDITION_SHAPES = {
        'allowed_ips' => [:ip_list_shape, ->(value) { value.is_a?(String) || (value.is_a?(Array) && value.all?(String)) }],
        'requires_session_flag' => [:flag_shape, ->(value) { value.is_a?(String) }],
        'allowed_hours_start' => [:hour_shape, ->(value) { value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A\s*-?\d+\s*\z/)) }],
        'allowed_hours_end' => [:hour_shape, ->(value) { value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A\s*-?\d+\s*\z/)) }]
      }.freeze

      before_action :set_permission_set, only: %i[show update destroy clone]

      def index
        scope = PermissionForge::PermissionSet.order(created_at: :desc)
        render_collection(scope, serializer_for(:permission_set))
      end

      def show
        render_record(@permission_set, serializer_for(:permission_set))
      end

      def create
        ps = PermissionForge::PermissionSet.new(permission_set_params)
        guard_mutation!(:create, ps)
        return if performed?

        save_set(ps) { render_created(ps, serializer_for(:permission_set)) }
      end

      # The lock is checked on the stored set, before the request's
      # attributes (is_editable among them) are assigned.
      def update
        guard_mutation!(:update, @permission_set)
        return if performed?

        @permission_set.assign_attributes(permission_set_params)
        save_set(@permission_set) { render_record(@permission_set, serializer_for(:permission_set)) }
      end

      def destroy
        guard_mutation!(:destroy, @permission_set)
        return if performed?

        @permission_set.destroy!
        head :no_content
      end

      def clone
        authorize_action!(:clone, @permission_set)
        return if performed?

        # As the admin's Duplicate: an editable copy, outside a locked group.
        # Names are unique per tenant: the default one is the admin's
        # "<name> (copy)" in the request's locale, numbered when taken.
        cloned = PermissionForge::Admin::PermissionSetFactory.duplicate(
          @permission_set, name: pf_text_param(:name).presence || PermissionForge::PermissionSet.copy_name(@permission_set.name)
        )
        render_created(cloned, serializer_for(:permission_set))
      end

      private

      # Saves a set whose attributes are assigned, unless it would enter or
      # leave a locked Permission Set Group (as the admin's group page
      # refuses); yields to render on success.
      def save_set(permission_set)
        locked = locked_group_for_move(permission_set)
        return reject_locked!(locked) if locked

        permission_set.save ? yield : render_validation_errors(permission_set)
      end

      def locked_group_for_move(permission_set)
        return unless permission_set.permission_set_group_id_changed?

        PermissionForge::Admin::EditableLock.locked_group_for_move(
          from: permission_set.permission_set_group_id_was, to: permission_set.permission_set_group_id
        )
      end

      def set_permission_set
        @permission_set = find_record(PermissionForge::PermissionSet)
      end

      # permission_set_group_id takes the group's id or, under
      # api_record_identifier = :uuid, its uuid (BaseController#with_reference_id).
      def permission_set_params
        section = pf_require_hash(:permission_set)
        attrs = section.permit(:name, :description, :is_active, :is_editable, :is_muting, :permission_set_group_id,
                               :requires_session_flag, :allowed_hours_start, :allowed_hours_end, :allowed_ips, allowed_ips: [])
        attrs = attrs.merge(condition_params(section))
        with_reference_id(attrs, :permission_set_group_id, PermissionForge::PermissionSetGroup)
      end

      # The condition attributes the request names, in a shape CONDITION_SHAPES
      # takes; the IP list normalised by the one parser (ActivationConditions).
      #
      # @raise [ParamShapes::InvalidParam] for any other shape (a 422 keyed by the attribute)
      def condition_params(section)
        CONDITION_SHAPES.each_with_object({}) do |(key, (message, shape)), conditions|
          next unless section.key?(key)

          value = section[key]
          value = nil if value == ''
          unless value.nil? || shape.call(value)
            raise PermissionForge::ParamShapes::InvalidParam.new(key, I18n.t("permission_forge.api.errors.#{message}"))
          end

          conditions[key] = key == 'allowed_ips' ? ip_list_param(value) : value
        end
      end

      # The IP list, its entries joined by commas. A list with no entry
      # (`[]`, `[""]`, `" , "`) is refused rather than read as "no
      # condition": null (or "") is how a client clears the condition.
      #
      # @raise [ParamShapes::InvalidParam]
      def ip_list_param(value)
        return if value.nil?

        PermissionForge::ActivationConditions.entries(value).join(',').presence ||
          raise(PermissionForge::ParamShapes::InvalidParam.new('allowed_ips', I18n.t('permission_forge.api.errors.ip_list_empty')))
      end
    end
  end
end
