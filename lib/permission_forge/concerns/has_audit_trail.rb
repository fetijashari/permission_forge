module PermissionForge
  module Concerns
    # @api private
    module HasAuditTrail
      extend ActiveSupport::Concern

      included do
        # class_name is config.audit_user_class as the model loads — after the
        # host's config/initializers, since the models are autoloaded by the
        # application (app/models). The callbacks are always registered but
        # no-op at runtime when audit_trail_enabled is false — so
        # config.audit_trail_enabled = false is a real toggle, not a
        # load-time-frozen one.
        belongs_to :created_by,
                   class_name: PermissionForge.configuration.audit_user_class,
                   optional: true

        belongs_to :updated_by,
                   class_name: PermissionForge.configuration.audit_user_class,
                   optional: true

        before_create :set_created_by
        before_update :set_updated_by
      end

      private

      # created_by is kept when given (a clone, an import); updated_by starts
      # as whoever created the row.
      def set_created_by
        return unless PermissionForge.configuration.audit_trail_enabled

        acting = audit_trail_user_id
        self.created_by_id ||= acting
        self.updated_by_id ||= acting || created_by_id
      end

      # Moves only to someone known: an edit by nobody (a job, a Basic-auth
      # login, an API client) keeps the previous editor instead of blanking it.
      def set_updated_by
        return unless PermissionForge.configuration.audit_trail_enabled

        acting = audit_trail_user_id
        self.updated_by_id = acting if acting
      end

      # The id of the acting user: the audit actor (an explicit
      # with_audit_actor block, the request's actor, else
      # PermissionForge.current_user) when it was made from a record of
      # config.audit_user_class — the class the two columns point at. An
      # admin of another model, or an actor given as a Hash, stamps nothing:
      # its id would name somebody else.
      def audit_trail_user_id
        actor = PermissionForge::Audit::Actor.current
        actor.id if actor.user_of?(PermissionForge.configuration.audit_user_class.to_s.safe_constantize)
      end
    end
  end
end
