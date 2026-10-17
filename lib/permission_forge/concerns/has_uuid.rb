module PermissionForge
  # The concerns a host includes in its own classes (`PermissionedUser`, `PermissionScopedFindable`,
  # `MaskedAttributes`, `ControllerActionGuard`, ...); the ones the gem uses on its own models are `@api private`.
  #
  # @api public
  module Concerns
    # @api private
    module HasUuid
      extend ActiveSupport::Concern

      included do
        before_create :generate_uuid, if: -> { respond_to?(:uuid) && uuid.blank? }

        validates :uuid, uniqueness: { message: ->(*) { I18n.t('permission_forge.validations.taken') } }, allow_nil: true
      end

      private

      def generate_uuid
        self.uuid = PermissionForge.configuration.uuid_generator.call
      end
    end
  end
end
