# frozen_string_literal: true

module PermissionForge
  # What the admin says when a copy (Duplicate, "Start from") is refused:
  # the row the validations refused and why, instead of a 500. A copy keeps
  # its original's stored values (Concerns::KeepsCopiedValues), so this is
  # left for a row no copy can hold (Modify All without View All, say); the
  # copy is made whole or not at all (one transaction).
  #
  # @api private
  module CopyRefusal
    # The record kinds a copy is made of, by class.
    KINDS = {
      'PermissionForge::PermissionSet' => :permission_set, 'PermissionForge::PermissionSetGroup' => :permission_set_group,
      'PermissionForge::Resource' => :resource, 'PermissionForge::ResourceField' => :resource_field,
      'PermissionForge::ResourceAction' => :resource_action, 'PermissionForge::PermissionSetRule' => :permission_set_rule
    }.freeze

    private

    # @param error [ActiveRecord::RecordInvalid]
    # @param name [String] the name of what was being copied
    # @return [String]
    def pf_copy_refused_message(error, name)
      record = error.record
      t('permission_forge.flash.copy_refused.message', name: name, record: pf_copy_refused_record(record),
                                                       errors: pf_copy_refused_errors(record.errors))
    end

    # "Resource “Customer”"
    def pf_copy_refused_record(record)
      t("permission_forge.flash.copy_refused.kinds.#{KINDS.fetch(record.class.name, :record)}", name: record.try(:name).to_s)
    end

    def pf_copy_refused_errors(errors)
      PermissionForge::Admin::ListSentence.call(PermissionForge::Admin::ErrorSentence.all(errors))
    end
  end
end
