# frozen_string_literal: true

module PermissionForge
  module Audit
    # Every ActiveJob job runs with source 'job' in the audit context. The
    # actor stays what the context already says (a job performed inline
    # inside an admin request keeps the admin) or what the job names with
    # PermissionForge.with_audit_actor; otherwise the usual resolution
    # (PermissionForge.current_user, else unknown).
    #
    # Installed by the engine through ActiveSupport.on_load(:active_job), so
    # an app without ActiveJob never loads it.
    #
    # @api private
    module JobContext
      def self.install!
        ActiveSupport.on_load(:active_job) { include PermissionForge::Audit::JobContext::Hook }
      end

      # Included into ActiveJob::Base.
      module Hook
        extend ActiveSupport::Concern

        included do
          around_perform do |_job, block|
            PermissionForge::Audit::Context.with(source: 'job') { block.call }
          end
        end
      end
    end
  end
end
