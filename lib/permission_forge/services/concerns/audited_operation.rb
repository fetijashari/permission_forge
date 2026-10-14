# frozen_string_literal: true

module PermissionForge
  module Services
    module Concerns
      # Runs a housekeeping service under an audit context: who ran it (`actor:`),
      # why (`reason:`), from where, and one correlation id for the per-row events
      # and the summary event it writes.
      #
      # `actor:` is a host user, an Audit::Actor, or a label String (stored as a
      # 'system' actor). nil names nobody: the context already in force (a request's
      # admin, a rake task's ACTOR, PermissionForge.current_user) stays — an explicit
      # nil never replaces a real actor.
      #
      # The source is 'service' unless the caller's context, or the process (rake,
      # console), already says where the call came from.
      module AuditedOperation
        private

        def audited(actor:, reason:, &)
          PermissionForge::Audit::Context.with(actor: audit_actor_for(actor), source: audit_source, reason: reason) do
            PermissionForge::Audit.correlate(&)
          end
        end

        # @return [PermissionForge::Audit::Actor, nil]
        def audit_actor_for(actor)
          case actor
          when nil then nil
          when String then PermissionForge::Audit::Actor.system(actor)
          else PermissionForge::Audit::Actor.coerce(actor)
          end
        end

        def audit_source
          return if PermissionForge::Audit::Context[:source]

          'service' if PermissionForge::Audit::Source.detect == 'service'
        end
      end
    end
  end
end
