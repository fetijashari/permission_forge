class Customer < ApplicationRecord
  include PermissionForge::Concerns::PermissionScopedFindable

  belongs_to :supplier, optional: true

  def self.extra_fields_for_permissions
    %w[full_address contact_count]
  end

  # Virtual (non-column) readers behind extra_fields_for_permissions. They read
  # the raw column values so what they return does not depend on how the
  # columns themselves are masked.
  def full_address
    [raw_column('name'), raw_column('domain')].compact_blank.join(', ')
  end

  def contact_count
    raw_column('email').present? ? 1 : 0
  end

  private

  def raw_column(name)
    read_attribute_before_type_cast(name)
  end
end
