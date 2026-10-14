module PermissionForge
  module Concerns
    # @api private
    module HasActiveScope
      extend ActiveSupport::Concern

      included do
        scope :active, -> { where(is_active: true) }
      end
    end
  end
end
