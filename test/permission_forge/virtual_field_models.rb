require 'test_helper'

# Dedicated models for the virtual-field tests. They sit on the dummy app's
# customers table, so no schema is added, and they are separate classes, so
# wrapping their readers (permanent for a class within the test process) never
# touches Customer. Top-level names: the admin only resolves models outside
# the PermissionForge namespace.

# Every kind of virtual field: declared methods, an attribute-API attribute and
# store accessors. Includes MaskedAttributes itself.
class PfVirtualProfile < ApplicationRecord
  self.table_name = 'customers'

  include PermissionForge::Concerns::MaskedAttributes

  attribute :nickname, :string
  store :domain, accessors: %i[theme], coder: JSON
  store_accessor :domain, :color, prefix: true
  store_accessor :domain, :size, suffix: true
  store_accessor :domain, :shade, prefix: :custom

  # `id` and `name` are the primary key and a column, `needs_argument` takes an
  # argument, `missing_reader` has no method, `attributes` is ActiveRecord's own.
  def self.extra_fields_for_permissions
    %w[display_name tags badge_count tier joined_on id name needs_argument missing_reader attributes greeting]
  end

  def display_name
    "#{read_attribute_before_type_cast('name')} / #{read_attribute_before_type_cast('email')}"
  end

  def tags
    %w[vip beta]
  end

  def badge_count
    3
  end

  def tier
    :gold
  end

  def joined_on
    Date.new(2024, 1, 2)
  end

  def needs_argument(format)
    "formatted:#{format}"
  end

  def greeting(prefix = 'Hello')
    "#{prefix}, #{read_attribute_before_type_cast('name')}"
  end
end

# Never has its readers wrapped by a test directly: the engine tests assert
# when the engine does it.
class PfVirtualEngineProfile < ApplicationRecord
  self.table_name = 'customers'

  include PermissionForge::Concerns::MaskedAttributes

  def self.extra_fields_for_permissions
    %w[display_name]
  end

  def display_name
    "#{read_attribute_before_type_cast('name')} (engine)"
  end
end

# Used by the admin tests (ModelCatalog, FieldRows, HTML). It does not include
# MaskedAttributes itself, but any test that creates a Resource named
# PfVirtualAccount gets the concern auto-applied to it for the rest of the
# process — so no test may assert that the concern is absent or present here.
class PfVirtualAccount < ApplicationRecord
  self.table_name = 'customers'

  attribute :nickname, :string
  store :domain, accessors: %i[theme], coder: JSON

  def self.extra_fields_for_permissions
    %w[full_address]
  end

  def full_address
    read_attribute_before_type_cast('name').to_s
  end
end

# Its extra-fields method always raises, so its declared names can never be
# read and `display_name` is never wrapped.
class PfVirtualBrokenProfile < ApplicationRecord
  self.table_name = 'customers'

  include PermissionForge::Concerns::MaskedAttributes

  def self.extra_fields_for_permissions
    raise ArgumentError, 'extra fields are broken'
  end

  def display_name
    "#{read_attribute_before_type_cast('name')} (broken)"
  end
end

# Shared by the virtual-field tests.
module VirtualFieldTestSupport
  private

  # Swaps klass.extra_fields_for_permissions for the block (minitest 6 ships
  # no stub helper). `names` is the list, or a callable that returns it.
  def with_extra_fields(klass, names)
    original = klass.method(:extra_fields_for_permissions)
    klass.redefine_singleton_method(:extra_fields_for_permissions) { names.respond_to?(:call) ? names.call : names }
    yield
  ensure
    klass.redefine_singleton_method(:extra_fields_for_permissions, &original)
  end

  # @return [String] what the block wrote to Rails.logger
  def captured_log
    output = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    yield
    output.string
  ensure
    Rails.logger = original
  end
end
