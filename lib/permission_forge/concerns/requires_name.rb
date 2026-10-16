# frozen_string_literal: true

module PermissionForge
  module Concerns
    # The one definition of "this record needs a name": a Permission Set, a
    # group, a rule, a Resource, a field row and an action row. A name that
    # is nil, empty or only whitespace is refused with
    # `permission_forge.validations.name_blank` — in code, through the JSON
    # API and in the admin alike.
    #
    # Checked for a new row and on a rename only: a row stored with a blank
    # name before (written past the model, or before 0.15 for a rule) stays
    # editable in its other attributes; the admin shows such a name as
    # "Untitled …" in the page's language (Admin::RecordName).
    #
    # Field test round 8 found a rule saved with name "" or "   " while sets
    # and groups refused it: each model declared the rule itself, and the rule
    # model never had it.
    #
    # @api private
    module RequiresName
      extend ActiveSupport::Concern

      included do
        validates :name, presence: { message: ->(*) { I18n.t('permission_forge.validations.name_blank') } },
                         if: :name_check_due?
      end

      private

      # A new row, or a change to its name.
      def name_check_due?
        new_record? || will_save_change_to_name?
      end
    end
  end
end
