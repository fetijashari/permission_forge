# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Association extension (`has_many ..., extend: AuditedCollection`) for
    # the collections the gem declares on its models and on the host's User.
    #
    # Rails' `collection.delete_all` and `collection.clear` remove rows with
    # one SQL statement and run no callbacks — even under
    # `dependent: :destroy` — so an assignment or membership removed that way
    # would leave no audit event and keep the person's cached permissions.
    # Here they remove each record the way `collection.delete(record)` does
    # (destroy under `dependent: :destroy`, the `before_remove` callbacks
    # otherwise), inside one transaction.
    #
    # An explicit strategy (`delete_all(:delete_all)`, `delete_all(:nullify)`)
    # and a narrowed relation (`collection.where(...).delete_all`, which
    # Rails extends with this module too) are the caller asking for SQL and
    # are left to Rails, like `Model.where(...).delete_all`.
    #
    # @api public
    module AuditedCollection
      # @return [Integer] the number of records removed
      def delete_all(dependent = nil)
        return super if dependent
        return super() unless is_a?(ActiveRecord::Associations::CollectionProxy)

        records = load_target.dup
        delete(*records) if records.any?
        records.size
      end
    end
  end
end
