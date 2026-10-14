require 'test_helper'
require_relative 'sti_models'

module PermissionForge
  # The one resolver of the Resource names a model class answers to, and of
  # how the user's entries along that chain compose.
  class ResourceChainTest < ActiveSupport::TestCase
    OPEN = { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' }.freeze
    MASKED = { read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email' }.freeze
    HIDDEN = { read_access: false, edit_access: false, mask_access: false, mask_strategy: 'full' }.freeze

    # A user whose hash has the given resource entries.
    def user_with(resources)
      user = Object.new
      hash = { permissions: { resources: resources } }
      user.define_singleton_method(:permissions_hash) { hash }
      user.define_singleton_method(:field_permissions) { |resource, field| resources.dig(resource.to_sym, :fields, field.to_sym) }
      user
    end

    def entry(permissions: {}, fields: {}, rules: [])
      { permissions: { read_access: true }.merge(permissions), fields: fields, actions: {}, source_permission_sets: [],
        permission_set_rules: rules }
    end

    def rule(name)
      { name: name, field_name: 'owner_id', operator: 'equal', field_value: 'current_user' }
    end

    test 'names: a plain model answers to its own name, an STI model to its own and its ancestors up to the base' do
      assert_equal [:Customer], ResourceChain.names(Customer)
      assert_equal [:PfStiTicket], ResourceChain.names(PfStiTicket)
      assert_equal %i[PfStiBugTicket PfStiTicket], ResourceChain.names(PfStiBugTicket)
      assert_equal %i[PfStiUrgentBugTicket PfStiBugTicket PfStiTicket], ResourceChain.names(PfStiUrgentBugTicket)
      assert_predicate ResourceChain.names(PfStiBugTicket), :frozen?
    end

    # Rails' base_class ignores table_name: a subclass with a table of its own
    # is not STI, and the base's rules (on columns it may lack) are not its.
    test 'names: a subclass with a table of its own answers to its own name only' do
      assert_equal [:PfStiArchivedTicket], ResourceChain.names(PfStiArchivedTicket)
      assert_equal PfStiTicket, PfStiArchivedTicket.base_class, 'Rails still calls PfStiTicket its base'
    end

    test 'names: a nameless subclass answers as its base, a renamed one once' do
      assert_equal [:Customer], ResourceChain.names(Class.new(Customer))
      assert_equal [:Customer], ResourceChain.names(Class.new(Customer) { def self.name = 'Customer' })
      assert_equal [:Object], ResourceChain.names(Object), 'not a model: its own name'
    end

    test 'names_for: the chain of the model a resource name names, or the name alone' do
      assert_equal %i[PfStiBugTicket PfStiTicket], ResourceChain.names_for('PfStiBugTicket')
      assert_equal [:Customer], ResourceChain.names_for(:Customer)
      assert_equal [:NoSuchModel], ResourceChain.names_for('NoSuchModel')
      assert_equal [:Kernel], ResourceChain.names_for('Kernel'), 'a constant that is not a class'
    end

    test 'rules: the rules of every entry apply together; a bypass skips only the entry that grants it' do
      base = rule('base')
      sub = rule('sub')
      names = %i[Sub Base]

      assert_equal [[sub, base], nil], ResourceChain.rules(user_with(Sub: entry(rules: [sub]), Base: entry(rules: [base])), names)
      assert_equal [[base], nil], ResourceChain.rules(user_with(Base: entry(rules: [base])), names), 'no entry of its own: the base'
      assert_equal [[base], nil],
                   ResourceChain.rules(user_with(Sub: entry(permissions: { view_all: true }, rules: [sub]), Base: entry(rules: [base])), names)
      assert_equal [[sub], nil],
                   ResourceChain.rules(user_with(Sub: entry(rules: [sub]), Base: entry(permissions: { modify_all: true }, rules: [base])), names)
    end

    test 'rules: the reason none apply is the nearest bypass, else no_rules' do
      names = %i[Sub Base]

      assert_equal [[], :no_rules], ResourceChain.rules(user_with({}), names)
      assert_equal [[], :no_rules], ResourceChain.rules(user_with(Base: entry), names)
      assert_equal [[], :view_all], ResourceChain.rules(user_with(Base: entry(permissions: { view_all: true })), names)
      assert_equal [[], :modify_all],
                   ResourceChain.rules(user_with(Sub: entry(permissions: { modify_all: true }), Base: entry(permissions: { view_all: true })),
                                       names)
    end

    test 'field_permissions: one configuring entry decides; of several, the strictest' do
      user = user_with(Sub: entry(fields: { email: OPEN, secret: OPEN, status: OPEN }),
                       Base: entry(fields: { email: MASKED, secret: HIDDEN, title: OPEN }))
      names = %i[Sub Base]

      assert_equal MASKED, ResourceChain.field_permissions(user, names, :email), 'masked in the base: masked'
      assert_equal HIDDEN.merge(mask_strategy: 'full'), ResourceChain.field_permissions(user, names, :secret), 'hidden in the base: hidden'
      assert_equal OPEN, ResourceChain.field_permissions(user, names, :status), 'only the subclass configures it'
      assert_equal OPEN, ResourceChain.field_permissions(user, names, :title), 'only the base configures it'
      assert_nil ResourceChain.field_permissions(user, names, :nothing)
      assert_same user.field_permissions(:Base, :title), ResourceChain.field_permissions(user, [:Base], :title), 'one name: the entry itself'
      assert_equal OPEN, ResourceChain.field_permissions(user, :Sub, :email), 'a bare name'
      assert_nil ResourceChain.field_permissions(Object.new, names, :email), 'a user without field_permissions'
    end

    test 'field_permissions: the strictest of several takes the first masking strategy, in chain order' do
      user = user_with(Sub: entry(fields: { email: MASKED.merge(mask_strategy: 'last4') }), Base: entry(fields: { email: MASKED }))

      assert_equal MASKED.merge(mask_strategy: 'last4'), ResourceChain.field_permissions(user, %i[Sub Base], :email)
      assert_equal MASKED, ResourceChain.field_permissions(user, %i[Base Sub], :email)
    end

    # Strictest wins along the chain: a class cannot be more readable than an
    # entry it answers to. Only among several entries — one entry is read as
    # a plain model's (its rows decide).
    test 'field_permissions and fields: an entry that does not grant read hides every field the chain configures' do
      user = user_with(Sub: entry(fields: { secret: OPEN, email: OPEN }),
                       Base: entry(permissions: { read_access: false }, fields: { email: HIDDEN }))
      names = %i[Sub Base]

      assert_equal HIDDEN, ResourceChain.field_permissions(user, names, :secret), 'configured by the subclass alone'
      assert_equal HIDDEN, ResourceChain.field_permissions(user, names, :email)
      assert_nil ResourceChain.field_permissions(user, names, :title), 'unconfigured stays unconfigured'
      assert_equal({ secret: HIDDEN, email: HIDDEN }, ResourceChain.fields(user, names))

      alone = user_with(Base: entry(permissions: { read_access: false }, fields: { email: OPEN }))
      assert_equal OPEN, ResourceChain.field_permissions(alone, [:Base], :email), 'one entry: its rows decide, as for a plain model'
      assert_equal OPEN, ResourceChain.field_permissions(alone, %i[Sub Base], :email), 'a subclass without a row is its base'
    end

    test 'fields: every configured name, composed the same way' do
      user = user_with(Sub: entry(fields: { email: OPEN, status: OPEN }), Base: entry(fields: { email: MASKED, title: OPEN }))

      assert_equal({ email: MASKED, status: OPEN, title: OPEN }, ResourceChain.fields(user, %i[Sub Base]))
      assert_equal({ email: MASKED, title: OPEN }, ResourceChain.fields(user, [:Base]))
      assert_equal({}, ResourceChain.fields(user, [:Nothing]))
    end
  end
end
