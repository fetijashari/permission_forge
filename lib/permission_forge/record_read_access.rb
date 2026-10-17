# frozen_string_literal: true

module PermissionForge
  # Whether a signed-in user's record reads of a model are refused whole,
  # before any row-level rule: the one definition behind
  # `config.no_read_access_strategy`, asked by find_by / find_by! /
  # permission_scoped (PermissionScopedFindable) and the default scope
  # (AutoPermissionScoping) before they hand the rules to
  # Services::PermissionRuleApplier.
  #
  # Under :rules_only (the default) never: the reads apply the rules of the
  # user's entries, and a user with no entry, or one that does not grant
  # read_access, has no rules and gets every row (can_read? is the check).
  # Under :deny (the strict preset) whenever the user's entries along the
  # class's Resource chain do not grant read_access
  # (ResourceChain.readable?): no entry at all, or one of them without read
  # — whatever took it away (no Permission Set grants it, a Muting
  # Permission Set, a Resource renamed off its model, a granting set whose
  # activation conditions do not pass or cannot be judged). View All and
  # Modify All skip the rules of a readable entry only.
  #
  # With nobody signed in nil_user_strategy decides; the rules are lifted
  # where they always were (the host's without_permission_scope, the
  # gem's own suspension of the default scope), and this with them.
  #
  # @api private
  module RecordReadAccess
    # The reason access.denied carries.
    REASON = :no_read_access

    module_function

    # @param user [#permissions_hash] the signed-in user
    # @param klass [Class] the model class read
    # @param configuration [PermissionForge::Configuration]
    # @return [Boolean]
    def denied?(user, klass, configuration: PermissionForge.configuration)
      configuration.deny_record_reads_without_read_access? &&
        !ResourceChain.readable?(user, ResourceChain.names(klass))
    end

    # What NotAuthorizedError#failure_messages says for such a denial, in
    # the current locale.
    #
    # @param klass [Class]
    # @return [String]
    def failure_message(klass)
      I18n.t('permission_forge.denials.no_read_access', resource: ResourceChain.names(klass).first || klass.name)
    end
  end
end
