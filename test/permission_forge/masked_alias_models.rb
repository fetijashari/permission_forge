require 'test_helper'

# Models for the alias_attribute and subclass tests of MaskedAttributes
# (concerns/masked_attribute_aliases_test.rb). Top-level names: the engine
# resolves a Resource row's name to a model. Never give a model here a Resource
# row unless its comment says it gets the concern that way — once applied, the
# concern stays on the class for the rest of the test process.

# A table with a `type` column, for the families below. Created here so the
# dummy schema stays as it is.
ActiveRecord::Schema.define do
  create_table :pf_alias_vehicles, force: true do |t|
    t.string :type
    t.string :uuid
    t.string :name
    t.string :email
    t.string :domain
  end
end

# --- one model per order in which the alias and the concern can arrive --------
# All on the dummy customers table. `mail` aliases a column the test user may
# not read, `title` a masked one and `site` a readable one.
module PfAliasDeclarations
  def pf_declare_aliases
    alias_attribute :mail, :email
    alias_attribute :title, :name
    alias_attribute :site, :domain
  end
end

# The alias first, the concern included by hand after it.
class PfAliasThenConcern < ApplicationRecord
  extend PfAliasDeclarations

  self.table_name = 'customers'
  pf_declare_aliases
  include PermissionForge::Concerns::MaskedAttributes
end

# The concern at the top of the class body, the alias after it.
class PfConcernThenAlias < ApplicationRecord
  extend PfAliasDeclarations

  self.table_name = 'customers'
  include PermissionForge::Concerns::MaskedAttributes

  pf_declare_aliases
end

# The alias declared and the model used, so Rails has generated its alias
# methods, before the concern arrives: the engine applies it when the model's
# first Resource row is created.
class PfAliasAutoApplied < ApplicationRecord
  extend PfAliasDeclarations

  self.table_name = 'customers'
  pf_declare_aliases
end
PfAliasAutoApplied.new.mail
PF_ALIAS_AUTO_APPLIED_GENERATED = PfAliasAutoApplied.send(:generated_attribute_methods).method_defined?(:mail)

# The concern included and the model used, so Rails has generated the
# attribute methods; the alias is declared after that.
class PfAliasOnUsedModel < ApplicationRecord
  extend PfAliasDeclarations

  self.table_name = 'customers'
  include PermissionForge::Concerns::MaskedAttributes
end
PfAliasOnUsedModel.new
PfAliasOnUsedModel.pf_declare_aliases

# The alias declared by a subclass of a model that has the concern.
class PfAliasParent < ApplicationRecord
  self.table_name = 'customers'
  include PermissionForge::Concerns::MaskedAttributes
end

class PfAliasChild < PfAliasParent
  extend PfAliasDeclarations

  pf_declare_aliases
end

# A subclass that declares the alias and is used before its parent gets the
# concern from the engine.
class PfAliasLateParent < ApplicationRecord
  self.table_name = 'customers'
end

class PfAliasLateChild < PfAliasLateParent
  extend PfAliasDeclarations

  pf_declare_aliases
end
PfAliasLateChild.new.mail
PF_ALIAS_LATE_CHILD_GENERATED = %i[mail email email=].all? do |name|
  PfAliasLateChild.send(:generated_attribute_methods).method_defined?(name)
end

# The alias declared on an abstract ancestor that never gets the concern.
class PfAliasAbstract < ApplicationRecord
  extend PfAliasDeclarations

  self.abstract_class = true
  pf_declare_aliases
end

class PfAliasConcrete < PfAliasAbstract
  self.table_name = 'customers'
  include PermissionForge::Concerns::MaskedAttributes
end

# --- single models --------------------------------------------------------------

# The model's own method under the alias's name, built on the alias.
class PfAliasOverridden < ApplicationRecord
  self.table_name = 'customers'
  include PermissionForge::Concerns::MaskedAttributes

  alias_attribute :mail, :email

  def mail
    "<#{super}>"
  end
end

# An alias of an attribute that is not a column.
class PfAliasVirtual < ApplicationRecord
  self.table_name = 'customers'
  include PermissionForge::Concerns::MaskedAttributes

  attribute :nickname, :string, default: 'Ace'
  alias_attribute :nick, :nickname
end

# An alias of the primary key, declared by the model.
class PfAliasOfId < ApplicationRecord
  self.table_name = 'customers'
  include PermissionForge::Concerns::MaskedAttributes

  alias_attribute :key, :id
end

# An alias that is pointed at another column once the model is in use.
class PfAliasRepointed < ApplicationRecord
  self.table_name = 'customers'
  include PermissionForge::Concerns::MaskedAttributes

  alias_attribute :site, :domain
end

# A subclass that declares the very alias its parent declares, used before the
# parent gets the concern from the engine: Rails generates the alias's methods
# in the subclass too.
class PfAliasRedeclaredParent < ApplicationRecord
  self.table_name = 'customers'
  alias_attribute :mail, :email
end

class PfAliasRedeclaredChild < PfAliasRedeclaredParent
  alias_attribute :mail, :email
end
PfAliasRedeclaredChild.new.mail

# --- twins: the same code with the concern and without it -----------------------
# A twin whose name starts with PfPlain never gets the concern: it is what
# plain Rails does on the Rails version under test.

# PfConcernThenAlias without the concern.
class PfPlainAliases < ApplicationRecord
  extend PfAliasDeclarations

  self.table_name = 'customers'
  pf_declare_aliases
end

module PfAliasCode
  # A module the model includes defines the reader and the writer under the
  # alias's name.
  module Titled
    def title
      "titled:#{super}"
    end

    def title=(value)
      super(value.to_s.strip.upcase)
    end

    def mail
      "m:#{super}"
    end
  end

  MODULE_METHODS = proc do
    self.table_name = 'customers'
    alias_attribute :title, :domain
    alias_attribute :mail, :email
    include Titled
  end

  # The model's own setter for the column writes through the alias.
  SETTER_THROUGH_ALIAS = proc do
    self.table_name = 'customers'
    alias_attribute :site, :domain

    def domain=(value)
      self.site = value.to_s.strip
    end
  end

  # The model's own setter for the column; the alias is written.
  CUSTOM_SETTER = proc do
    self.table_name = 'customers'
    alias_attribute :site, :domain

    def domain=(value)
      super(value.to_s.downcase)
    end
  end

  # An alias of an alias.
  CHAIN = proc do
    self.table_name = 'customers'
    alias_attribute :mail, :email
    alias_attribute :mail2, :mail
  end

  # Rails 7.1 only: an alias of a private method that is not an attribute.
  PRIVATE_TARGET = proc do
    self.table_name = 'customers'
    alias_attribute :shout, :loud

    private

    def loud
      'LOUD'
    end
  end

  # A family on the table with a `type` column. The parent declares the
  # aliases and has its own reader and writer under an alias's name.
  VEHICLE = proc do
    self.table_name = 'pf_alias_vehicles'
    alias_attribute :label, :domain
    alias_attribute :mail, :email
    alias_attribute :title, :name

    def label
      "vehicle:#{super}"
    end

    def label=(value)
      super("set:#{value}")
    end

    def mail
      "m:#{super}"
    end
  end

  # A subclass with readers of its own for two columns.
  TRUCK = proc do
    def domain
      "truck:#{super}"
    end

    def name
      "truck:#{super}"
    end

    def domain=(value)
      super("trucked:#{value}")
    end
  end

  # A module a subclass includes, with a reader for a column.
  module Loud
    def domain
      super.to_s.upcase
    end
  end

  # A subclass defined now. For a class that must exist only once its parent
  # has the concern (the lazy-loading order): call it after the grant.
  def self.late(name, parent, &)
    return Object.const_get(name) if Object.const_defined?(name)

    Object.const_set(name, Class.new(parent, &))
  end
end

# The engine applies the concern to it; it was in use before.
class PfAliasModuleMethods < ApplicationRecord
  class_eval(&PfAliasCode::MODULE_METHODS)
end
PfAliasModuleMethods.new.then { |record| [record.title, record.mail] }

# The concern at the bottom of the class body.
class PfAliasModuleMethodsBottom < ApplicationRecord
  class_eval(&PfAliasCode::MODULE_METHODS)
  include PermissionForge::Concerns::MaskedAttributes
end

class PfPlainModuleMethods < ApplicationRecord
  class_eval(&PfAliasCode::MODULE_METHODS)
end

class PfAliasSetterThroughAlias < ApplicationRecord
  self.table_name = 'customers'
  include PermissionForge::Concerns::MaskedAttributes

  class_eval(&PfAliasCode::SETTER_THROUGH_ALIAS)
end

class PfPlainSetterThroughAlias < ApplicationRecord
  class_eval(&PfAliasCode::SETTER_THROUGH_ALIAS)
end

class PfAliasCustomSetter < ApplicationRecord
  self.table_name = 'customers'
  include PermissionForge::Concerns::MaskedAttributes

  class_eval(&PfAliasCode::CUSTOM_SETTER)
end

class PfPlainCustomSetter < ApplicationRecord
  class_eval(&PfAliasCode::CUSTOM_SETTER)
end

class PfAliasChain < ApplicationRecord
  self.table_name = 'customers'
  include PermissionForge::Concerns::MaskedAttributes

  class_eval(&PfAliasCode::CHAIN)
end

class PfPlainChain < ApplicationRecord
  class_eval(&PfAliasCode::CHAIN)
end

if ActiveRecord.version < Gem::Version.new('7.2')
  class PfAliasPrivateTarget < ApplicationRecord
    self.table_name = 'customers'
    include PermissionForge::Concerns::MaskedAttributes

    class_eval(&PfAliasCode::PRIVATE_TARGET)
  end

  class PfPlainPrivateTarget < ApplicationRecord
    class_eval(&PfAliasCode::PRIVATE_TARGET)
  end
end

if ActiveRecord.version < Gem::Version.new('7.2')
  # Rails 7.1 only. A parent without the concern whose setter for an alias's
  # target is private; one subclass gets the concern from the engine
  # (PfPrivateSetterGuarded).
  PF_PRIVATE_SETTER = proc do
    self.table_name = 'customers'
    alias_attribute :site, :domain

    private

    def domain=(value)
      super("w:#{value}")
    end
  end

  class PfPrivateSetterHolder < ApplicationRecord
    class_eval(&PF_PRIVATE_SETTER)
  end

  class PfPrivateSetterGuarded < PfPrivateSetterHolder; end

  class PfPlainPrivateSetter < ApplicationRecord
    class_eval(&PF_PRIVATE_SETTER)
  end

  # Rails 7.1 only. A column named like an Active Record method, kept the
  # usual way, and an alias of it. The parent never gets the concern; one
  # subclass gets it from the engine (PfReservedGuarded).
  ActiveRecord::Schema.define do
    create_table :pf_alias_counters, force: true do |t|
      t.string :type
      t.integer :increment
    end
  end

  PF_RESERVED_TARGET = proc do
    self.table_name = 'pf_alias_counters'

    def self.instance_method_already_implemented?(method_name)
      method_name.to_s == 'increment' || super
    end

    alias_attribute :step, :increment
  end

  class PfReservedHolder < ApplicationRecord
    class_eval(&PF_RESERVED_TARGET)
  end

  class PfReservedGuarded < PfReservedHolder; end
  class PfReservedBystander < PfReservedHolder; end

  class PfPlainReserved < ApplicationRecord
    class_eval(&PF_RESERVED_TARGET)
  end
end

# The family that gets the concern from the engine, on its parent. PfVehicle,
# PfTruck, PfPickup and PfVan were in use before; PfCar was only loaded, which
# is what eager loading leaves behind.
class PfVehicle < ApplicationRecord
  class_eval(&PfAliasCode::VEHICLE)
end

class PfCar < PfVehicle; end

class PfTruck < PfVehicle
  class_eval(&PfAliasCode::TRUCK)
end

class PfPickup < PfTruck; end

class PfVan < PfVehicle
  include PfAliasCode::Loud
end
[PfVehicle, PfTruck, PfPickup, PfVan].each do |model|
  model.new.then { |record| [record.label, record.mail, record.domain, record.name] }
end
PF_ALIAS_FAMILY_GENERATED = [PfVehicle, PfCar, PfTruck, PfPickup, PfVan].to_h do |model|
  [model, model.send(:generated_attribute_methods).method_defined?(:email, false)]
end.freeze

# Its twin without the concern.
class PfPlainVehicle < ApplicationRecord
  class_eval(&PfAliasCode::VEHICLE)
end

class PfPlainCar < PfPlainVehicle; end

class PfPlainTruck < PfPlainVehicle
  class_eval(&PfAliasCode::TRUCK)
end

class PfPlainPickup < PfPlainTruck; end

class PfPlainVan < PfPlainVehicle
  include PfAliasCode::Loud
end

# The parent declares the aliases and never gets the concern; one subclass
# gets it from the engine (PfHeldGuarded), the other never does.
class PfHolder < ApplicationRecord
  class_eval(&PfAliasCode::VEHICLE)
end

class PfHeldGuarded < PfHolder; end
class PfHeldBystander < PfHolder; end
[PfHolder, PfHeldGuarded, PfHeldBystander].each { |model| model.new.then { |record| [record.label, record.mail] } }

# A parent without the concern that points its alias at another column once
# one of its subclasses has the concern.
class PfRepointHolder < ApplicationRecord
  self.table_name = 'pf_alias_vehicles'
  alias_attribute :site, :domain

  def name
    "held:#{super}"
  end
end

class PfRepointGuarded < PfRepointHolder; end
class PfRepointBystander < PfRepointHolder; end
[PfRepointGuarded, PfRepointBystander].each { |model| model.new.site }

# Every class of the hierarchy gets a Resource row, the leaf first.
class PfLeafFirstRoot < ApplicationRecord
  self.table_name = 'pf_alias_vehicles'
  alias_attribute :mail, :email
end

class PfLeafFirstMiddle < PfLeafFirstRoot; end

class PfLeafFirstLeaf < PfLeafFirstMiddle
  alias_attribute :title, :name
end
[PfLeafFirstRoot, PfLeafFirstMiddle, PfLeafFirstLeaf].each { |model| model.new.mail }

# A subclass used before its parent gets the concern, whose attribute methods
# Rails has undefined (reset_column_information) and not generated again when
# the concern arrives.
class PfResetParent < ApplicationRecord
  self.table_name = 'pf_alias_vehicles'
end

class PfResetChild < PfResetParent
  alias_attribute :mail, :email
end
PfResetChild.new.mail
PfResetChild.undefine_attribute_methods

# Read by other threads while the engine applies the concern to its parent.
class PfBusyParent < ApplicationRecord
  self.table_name = 'pf_alias_vehicles'
end

class PfBusyChild < PfBusyParent
  alias_attribute :mail, :email
end

# Read at every step the main thread takes while it applies the concern to
# the parent.
class PfSteppedParent < ApplicationRecord
  self.table_name = 'pf_alias_vehicles'
end

class PfSteppedChild < PfSteppedParent
  alias_attribute :mail, :email
end
