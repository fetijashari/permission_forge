# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # The user model (config.user_class): what sign-in needs from it, which
      # runs before anyone is signed in, and what it shows then.
      class UserModelCheck < BaseCheck
        RULES = %i[user_model_scoped user_model_unmasked_without_user].freeze

        def call
          return [] unless user_model

          RULES.filter_map { |rule| send(rule) }
        end

        private

        def user_model
          return @user_model if defined?(@user_model)

          model = configuration.user_class.to_s.safe_constantize
          @user_model = model.is_a?(Class) ? model : nil
        end

        # Record rules on the user model, with nobody signed in denied.
        def user_model_scoped
          return unless user_model < PermissionForge::Concerns::PermissionScopedFindable
          return unless %i[deny raise].include?(configuration.nil_user_strategy)

          finding(:low, :user_model_scoped, 'The user model cannot be looked up before sign-in',
                  "#{user_model.name} includes PermissionScopedFindable and nil_user_strategy is " \
                  ":#{configuration.nil_user_strategy}: sign-in, session restore, password reset and " \
                  'confirmation run before anyone is signed in, and their lookups (where, find_by, ' \
                  'authenticate_by) find nothing. Remove the concern from the user model (scope a user ' \
                  'directory with permission_scoped in its controller), or run those lookups inside ' \
                  'PermissionForge.without_permission_scope.')
        end

        # :hide and :hide_in_requests exempt the user model so sign-in can read it.
        def user_model_unmasked_without_user
          return unless configuration.hide_masked_attributes_without_user_in_requests?

          names = user_model_resource_names
          return if names.empty?

          finding(:low, :user_model_unmasked_without_user, 'The user model is not masked with nobody signed in',
                  "masked_attributes_nil_user_strategy is :#{configuration.masked_attributes_nil_user_strategy}, " \
                  'but the user model is exempt so that sign-in ' \
                  "can read it: with nobody signed in, #{user_model.name}'s columns — password digests and " \
                  'reset or confirmation tokens included — read as stored through its getters and as_json. ' \
                  'Do not render it with no current user. Another authenticatable model (a second Devise ' \
                  'scope) is not exempt: with a Resource row its sign-in reads hidden values.',
                  items: names)
        end

        # The Resource names that mask the user model: its own and its STI
        # ancestors' (ResourceChain), and its subclasses'.
        def user_model_resource_names
          chain = PermissionForge::ResourceChain.names(user_model).map(&:to_s)
          PermissionForge::Resource.distinct.order(:name).pluck(:name).select do |name|
            chain.include?(name) || configuration.user_model_class?(name.safe_constantize)
          end
        end
      end
    end
  end
end
