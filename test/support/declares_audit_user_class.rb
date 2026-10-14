# frozen_string_literal: true

# Declares created_by / updated_by of PermissionForge::PermissionSetUser
# against another audit user model — what the class would have declared had
# it loaded with config.audit_user_class = name (HasAuditTrail reads the
# configuration as the model loads; the gem rebinds nothing after boot).
# Ruby's redefinition warnings are silenced: this is the test re-declaring
# an association, not the gem.
module DeclaresAuditUserClass
  def declare_audit_user_class(name)
    PermissionForge.configuration.audit_user_class = name
    silence_warnings do
      PermissionForge::PermissionSetUser.belongs_to :created_by, class_name: name, optional: true
      PermissionForge::PermissionSetUser.belongs_to :updated_by, class_name: name, optional: true
    end
  end
end
