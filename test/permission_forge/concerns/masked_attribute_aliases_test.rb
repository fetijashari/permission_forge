require 'test_helper'
require_relative '../masked_alias_models'

# Shared by the two test classes below.
module PfAliasTestSupport
  ADDRESS = 'contact@acme.com'.freeze
  MASK = ('*' * 8).freeze

  private

  # A Resource row (the first one for a model makes the engine apply the
  # concern to it) and field rows: email hidden, name masked, the rest readable.
  def grant(model, **fields)
    resource = create_resource(permission_set: @set, name: model.name, read_access: true, edit_access: true)
    levels = { 'email' => { read_access: false }, 'name' => { mask_access: true, mask_strategy: 'full' },
               'domain' => {}, 'uuid' => {}, 'type' => {} }.merge(fields.stringify_keys)
    levels.each do |name, flags|
      flags = { read_access: true }.merge(flags)
      create_resource_field(resource: resource, name: name, label: name.humanize, edit_access: flags[:read_access], **flags)
    end
  end

  # Rows for every model, in the order given: a parent before its subclasses,
  # unless the test is about the other order.
  def protect(*models, **fields)
    models.each { |model| grant(model, **fields) }
    @user.regenerate_permissions
  end

  # A stored record, read back under whoever is the current user. The columns
  # are set past the model's own setters.
  def row(klass)
    current = Current.user
    Current.user = nil
    id = klass.create!(uuid: SecureRandom.uuid).id
    klass.where(id: id).update_all(name: 'Acme Corp', email: ADDRESS, domain: 'acme.com')
    Current.user = current
    klass.find(id)
  end

  def stored(record, column)
    klass = record.class
    klass.connection.select_value("SELECT #{column} FROM #{klass.table_name} WHERE id = #{record.id.to_i}")
  end
end

module PermissionForge
  module Concerns
    # An alias is not a field of its own: every way of reading or writing it
    # gets the level of the attribute it points to, whenever the alias, the
    # concern and Rails' generated methods came into existence.
    class MaskedAttributeAliasesTest < ActiveSupport::TestCase
      include PfAliasTestSupport

      # model => the models that need a Resource row for it to be masked
      MODELS = {
        ::PfAliasThenConcern => [::PfAliasThenConcern],
        ::PfConcernThenAlias => [::PfConcernThenAlias],
        ::PfAliasAutoApplied => [::PfAliasAutoApplied],
        ::PfAliasOnUsedModel => [::PfAliasOnUsedModel],
        ::PfAliasChild => [::PfAliasParent, ::PfAliasChild],
        ::PfAliasLateChild => [::PfAliasLateParent, ::PfAliasLateChild],
        ::PfAliasConcrete => [::PfAliasConcrete]
      }.freeze

      setup do
        @config = PermissionForge.configuration
        @user = create_user
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @config.unconfigured_field_strategy = :block
      end

      teardown do
        @config.hidden_attribute_value = nil
        @config.omit_hidden_in_attributes_hash = true
        @config.mask_virtual_attributes = false
        @config.on_field_filtered = nil
      end

      # Resource and field rows, and a record read back as the user.
      def record_of(klass, granted = MODELS.fetch(klass), **fields)
        protect(*granted, **fields)
        Current.user = @user
        row(klass)
      end

      MODELS.each_key do |klass|
        test "#{klass}: has the concern" do
          record_of(klass)

          assert_operator klass, :<, MaskedAttributes
        end

        test "#{klass}: the alias reader returns what the column's getter returns" do
          record = record_of(klass)

          assert_nil record.mail
          assert_equal MASK, record.title
          assert_equal 'acme.com', record.site
          assert_equal([nil, MASK], %i[mail title].map { |reader| record.public_send(reader) })
        end

        test "#{klass}: the alias reader holds when Rails generates its attribute methods again" do
          record = record_of(klass)
          klass.undefine_attribute_methods
          klass.define_attribute_methods

          assert_nil record.mail
          assert_nil klass.find(record.id).mail
          assert_equal MASK, klass.find(record.id).title
        end

        test "#{klass}: [] and read_attribute judge the alias by its column, not as an unconfigured field" do
          record = record_of(klass)

          %i[block pass_through].each do |strategy|
            @config.unconfigured_field_strategy = strategy

            assert_nil record[:mail], strategy
            assert_nil record.read_attribute(:mail), strategy
            assert_equal MASK, record['title'], strategy
            assert_equal MASK, record.read_attribute('title'), strategy
            assert_equal 'acme.com', record[:site], strategy
          end
        end

        test "#{klass}: serialization gives the alias the column's treatment" do
          record = record_of(klass)

          json = record.as_json(methods: %i[mail title site])

          assert_not json.key?('mail'), 'an alias of a hidden column is dropped, like the column'
          assert_equal MASK, json['title']
          assert_equal 'acme.com', json['site']
          assert_empty record.as_json(only: %i[mail title])
          assert_nil record.read_attribute_for_serialization(:mail)
          assert_equal({ 'mail' => nil, 'title' => MASK }, record.slice(:mail, :title))
          assert_not_includes record.to_json(methods: :mail), ADDRESS
          assert_not_includes record.serializable_hash(methods: [:mail]).values, ADDRESS
        end

        test "#{klass}: with hidden keys kept, the alias carries the hidden value" do
          @config.omit_hidden_in_attributes_hash = false
          @config.hidden_attribute_value = '[hidden]'
          record = record_of(klass)

          assert_equal '[hidden]', record.as_json(methods: [:mail])['mail']
          assert_equal '[hidden]', record.mail
        end

        test "#{klass}: mail? answers as email? does" do
          record = record_of(klass)

          assert_equal record.email?, record.mail?
          assert_not record.mail?
          assert_equal record.name?, record.title?
        end

        # *_before_type_cast is the documented raw path, for an alias as for
        # its column; the dirty helpers read the raw change set for both.
        test "#{klass}: the raw and dirty helpers of an alias are those of its column" do
          record = record_of(klass)

          assert_equal ADDRESS, record.email_before_type_cast
          assert_equal record.email_before_type_cast, record.mail_before_type_cast
          assert_equal record.email_was, record.mail_was
          assert_equal record.email_changed?, record.mail_changed?

          Current.user = nil
          record.email = 'new@acme.com'
          Current.user = @user

          %w[was change changed? in_database for_database before_type_cast].each do |suffix|
            assert_equal record.public_send("email_#{suffix}"), record.public_send("mail_#{suffix}"), suffix
          end
          assert_equal [ADDRESS, 'new@acme.com'], record.mail_change

          record.save!

          assert_equal record.saved_change_to_email, record.saved_change_to_mail
          assert_equal record.email_before_last_save, record.mail_before_last_save
          assert_equal ADDRESS, record.mail_before_last_save
        end

        test "#{klass}: writing the hidden or masked value back through the alias is skipped" do
          record = record_of(klass)

          hidden = record.email
          masked = record.title

          assert_nil hidden
          assert_equal MASK, masked

          record.mail = hidden
          record.title = masked
          record.save!

          assert_equal ADDRESS, stored(record, 'email')
          assert_equal 'Acme Corp', stored(record, 'name')
        end

        test "#{klass}: a mask posted back onto a fresh record through the alias is skipped" do
          record = record_of(klass)

          record.title = MASK
          record.assign_attributes(mail: nil)
          record.save!

          assert_equal 'Acme Corp', stored(record, 'name')
          assert_equal ADDRESS, stored(record, 'email')
        end

        test "#{klass}: the alias setter raises under :raise, as the column setter does" do
          @config.masked_write_protection = :raise
          record = record_of(klass)

          assert_raises(MaskedAttributes::MaskedWriteError) { record.title = MASK }
          assert_raises(MaskedAttributes::MaskedWriteError) { record.name = MASK }
        end

        test "#{klass}: a value read through the alias cannot be written back through the column" do
          @config.hidden_attribute_value = '[hidden]'
          record = record_of(klass)

          record.email = record[:mail]
          record.save!

          assert_equal ADDRESS, stored(record, 'email')
        end

        test "#{klass}: a new value written through the alias is stored" do
          record = record_of(klass)

          record.mail = 'new@acme.com'
          record.title = 'Renamed'
          record.save!

          assert_equal 'new@acme.com', stored(record, 'email')
          assert_equal 'Renamed', stored(record, 'name')
        end

        test "#{klass}: without a current user the alias reads and writes the real value" do
          record = record_of(klass)
          Current.user = nil

          assert_equal ADDRESS, record.mail
          assert_equal 'Acme Corp', record[:title]

          record.mail = nil
          record.save!

          assert_nil stored(record, 'email')
        end

        test "#{klass}: an alias of an attribute that was not loaded raises, as on any model" do
          record = record_of(klass)
          partial = klass.select(:id).find(record.id)

          assert_raises(ActiveModel::MissingAttributeError) { partial.mail }
          assert_raises(ActiveModel::MissingAttributeError) { partial[:mail] }
          assert_nil partial.read_attribute(:mail)
        end
      end

      test 'Rails had generated the alias and column methods before the engine applied the concern' do
        assert PF_ALIAS_AUTO_APPLIED_GENERATED
        assert PF_ALIAS_LATE_CHILD_GENERATED
      end

      # Not an alias path, but the same race: the subclass generated its own
      # column methods before its parent had the concern.
      test 'a subclass used before its parent got the concern has masked column accessors' do
        record = record_of(::PfAliasLateChild)

        assert_nil record.email
        assert_equal MASK, record.name
        assert_not record.email?

        record.name = MASK
        record.email = nil
        record.save!

        assert_equal 'Acme Corp', stored(record, 'name')
        assert_equal ADDRESS, stored(record, 'email')
      end

      # Paths the concern does not cover for a column (docs/masked-attributes.md):
      # an alias opens nothing more and nothing less than its column does.
      test 'what is raw or unguarded for a column is the same for its alias, no more' do
        record = record_of(::PfConcernThenAlias)
        other = ::PfConcernThenAlias.find(::PfConcernThenAlias.create!(uuid: SecureRandom.uuid, name: 'Acme Corp').id)

        assert_equal record.attribute_for_inspect(:email), record.attribute_for_inspect(:mail)
        assert_equal record.attribute_present?(:email), record.attribute_present?(:mail)
        assert_equal ::PfConcernThenAlias.where(id: record.id).pluck(:email), ::PfConcernThenAlias.where(id: record.id).pluck(:mail)
        assert_equal record.values_at(:email, :name), record.values_at(:mail, :title)

        record.write_attribute(:name, MASK)
        other.write_attribute(:title, MASK)
        [record, other].each(&:save!)

        assert_equal stored(record, 'name'), stored(other, 'name')

        record[:name] = 'Acme Corp'
        other[:title] = 'Acme Corp'
        [record, other].each(&:save!)

        assert_equal stored(record, 'name'), stored(other, 'name')
      end

      test 'the alias is readable when its column is' do
        record = record_of(::PfConcernThenAlias, email: {}, name: {})

        assert_equal ADDRESS, record.mail
        assert_equal ADDRESS, record[:mail]
        assert_equal 'Acme Corp', record.title
        assert_equal ADDRESS, record.as_json(methods: [:mail])['mail']
      end

      test 'an alias of a masked column is masked with the column strategy' do
        record = record_of(::PfConcernThenAlias, email: { mask_access: true, mask_strategy: 'email' })

        assert_equal 'c***@acme.com', record.mail
        assert_equal 'c***@acme.com', record[:mail]
        assert_equal 'c***@acme.com', record.as_json(methods: [:mail])['mail']

        record.mail = 'c***@acme.com'
        record.save!

        assert_equal ADDRESS, stored(record, 'email')
      end

      test 'a field row named after the alias changes nothing' do
        record = record_of(::PfConcernThenAlias, mail: {}, title: { read_access: false })

        assert_nil record.mail
        assert_nil record[:mail]
        assert_equal MASK, record.title
      end

      test "the model's own method under the alias name is built on the masked value" do
        record = record_of(::PfAliasOverridden, [::PfAliasOverridden])

        assert_equal '<>', record.mail
        assert_nil record[:mail]

        Current.user = nil

        assert_equal "<#{ADDRESS}>", record.mail
      end

      test 'an alias of the primary key is left to Rails' do
        record = record_of(::PfConcernThenAlias)

        plain = row(::PfPlainAliases)

        assert_equal record.id, record.id_value
        # Up to Rails 8.1 `id_value` is an alias of `id`, so `[]` reads the id;
        # from Rails 8.2 a model with a one-column key gets a plain `id_value`
        # reader instead, and `[]` finds no attribute of that name.
        if plain[:id_value].nil?
          assert_nil record[:id_value]
        else
          assert_equal plain.id, plain[:id_value]
          assert_equal record.id, record[:id_value]
        end
      end

      test 'an alias of the primary key gets no accessor: the method Rails generates answers' do
        record = record_of(::PfAliasOfId, [::PfAliasOfId])

        assert_equal record.id, record.key
        assert_equal record.id, record[:key]
        assert_not ::PfAliasOfId.const_defined?(:MaskedAliasAccessors, false)
        assert_not_includes ::PfConcernThenAlias::MaskedAliasAccessors.instance_methods(false), :id_value
      end

      # --- the accessors do what the Rails version in use does, plus the guard ------

      # What the block does with a fresh record of `klass`: its value, or the
      # error class.
      def outcome(klass)
        yield row(klass)
      rescue StandardError, SystemStackError => e
        e.class
      end

      # With no current user the model answers as its twin, which never had
      # the concern.
      def assert_as_plain_rails(model, twin, &)
        Current.user = nil
        expected = outcome(twin, &)
        actual = outcome(model, &)
        expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
        expected
      end

      [::PfAliasModuleMethods, ::PfAliasModuleMethodsBottom].each do |klass|
        test "#{klass}: a reader and a writer a module defines under the alias's name still run" do
          record = record_of(klass, [klass])

          assert_equal 'titled:acme.com', record.title
          assert_equal 'm:', record.mail, 'built on the hidden value'
          assert_nil record[:mail]

          record.title = '  spaced  '
          record.save!

          assert_equal 'SPACED', stored(record, 'domain')
        end

        test "#{klass}: with no current user those methods give what they give in plain Rails" do
          protect(klass)

          assert_as_plain_rails(klass, ::PfPlainModuleMethods) do |record|
            record.title = '  spaced  '
            [record.title, record.mail, record.read_attribute_before_type_cast('domain')]
          end
        end
      end

      # Rails 7.2 and later write the attribute; 7.1 calls the model's setter.
      test "writing an alias reaches the model's own setter for the column where Rails does, and only there" do
        protect(::PfAliasCustomSetter)

        written = assert_as_plain_rails(::PfAliasCustomSetter, ::PfPlainCustomSetter) do |record|
          record.site = 'UPPER.EXAMPLE'
          assigned = record.read_attribute_before_type_cast('domain')
          record.update!(site: 'SAVED.EXAMPLE')
          [assigned, stored(record, 'domain'), record.class.new(site: 'NEW.EXAMPLE').read_attribute_before_type_cast('domain')]
        end

        expected = %w[UPPER.EXAMPLE SAVED.EXAMPLE NEW.EXAMPLE]

        assert_equal(ActiveRecord.version < Gem::Version.new('7.2') ? expected.map(&:downcase) : expected, written)
      end

      # Plain Rails 7.1 calls the setter from the alias and never returns.
      test "the model's own setter for the column may write through the alias where Rails lets it" do
        written = assert_as_plain_rails(::PfAliasSetterThroughAlias, ::PfPlainSetterThroughAlias) do |record|
          record.domain = ' a.example '
          record.read_attribute_before_type_cast('domain')
        end

        assert_equal(ActiveRecord.version < Gem::Version.new('7.2') ? SystemStackError : 'a.example', written)
      end

      test 'an alias of an alias is judged as the attribute at the end and reads what Rails reads' do
        record = record_of(::PfAliasChain, [::PfAliasChain])

        %i[block warn pass_through].each do |strategy|
          @config.unconfigured_field_strategy = strategy

          assert_nil record.mail2, strategy
          assert_nil record[:mail2], strategy
          assert_nil record.read_attribute(:mail2), strategy
          assert_nil record.mail, strategy
        end
        assert_not record.as_json(methods: [:mail2]).key?('mail2')

        judged = []
        @config.on_field_filtered = ->(field_name:, action:, **) { judged << [field_name, action] }
        record[:mail2]
        @config.on_field_filtered = nil

        assert_equal [%i[email hidden]], judged

        assert_as_plain_rails(::PfAliasChain, ::PfPlainChain) do |plain|
          [plain.mail, plain.mail2, plain[:mail2], plain.read_attribute(:mail2)]
        end
        assert_as_plain_rails(::PfAliasChain, ::PfPlainChain) { |plain| plain.mail2 = 'x' }
      end

      test 'a chain of aliases is followed to its end, and ends when aliases point at each other' do
        access = MaskedAttributes::AliasAccess

        assert_equal 'email', access.chain_end({ 'mail2' => 'mail', 'mail' => 'email' }, 'mail')
        assert_equal 'email', access.chain_end({ 'mail3' => 'mail2', 'mail2' => 'mail', 'mail' => 'email' }, 'mail2')
        assert_equal 'email', access.target(::PfAliasChain, :mail2)
        assert_nil access.target(::PfAliasChain, :email)
        assert_includes %w[a b], access.chain_end({ 'a' => 'b', 'b' => 'a' }, 'b')
      end

      if defined?(::PfAliasPrivateTarget)
        test 'Rails 7.1: an alias of a private method that is not an attribute answers as in plain Rails' do
          assert ::PfAliasPrivateTarget.private_method_defined?(:loud)
          assert_equal 'LOUD', ::PfAliasPrivateTarget.new.shout
          assert_as_plain_rails(::PfAliasPrivateTarget, ::PfPlainPrivateTarget) { |record| [record.shout, record.shout?] }
          assert_equal NoMethodError, assert_as_plain_rails(::PfAliasPrivateTarget, ::PfPlainPrivateTarget) { |record| record.shout = 'x' }
        end
      end

      if defined?(::PfPrivateSetterHolder)
        test "Rails 7.1: a private setter for an alias's target is called, as in plain Rails" do
          protect(::PfPrivateSetterGuarded)
          Current.user = nil

          stored = [::PfPlainPrivateSetter, ::PfPrivateSetterHolder, ::PfPrivateSetterGuarded].map do |klass|
            record = klass.new
            record.site = 'v9'
            record.read_attribute_before_type_cast('domain')
          end

          assert ::PfPrivateSetterHolder.private_method_defined?(:domain=)
          assert_equal ['w:v9'] * 3, stored
        end

        # Rails does not count a method of its own (`increment`) as the model's
        # reader for a column of that name; an alias of the column reads it.
        test 'Rails 7.1: an alias of a column named like an Active Record method reads the column, as in plain Rails' do
          protect(::PfReservedGuarded)
          Current.user = nil

          answers = [::PfPlainReserved, ::PfReservedHolder, ::PfReservedBystander].map do |klass|
            record = klass.find(klass.create!(increment: 3).id)
            before = record.step
            record.step = 9
            [before, record[:increment]]
          end

          assert_equal [[3, 9]] * 3, answers
        end
      end

      test 'an alias declared again with another column follows the new column' do
        record = record_of(::PfAliasRepointed, [::PfAliasRepointed])

        assert_equal 'acme.com', record.site

        ::PfAliasRepointed.alias_attribute :site, :email

        assert_nil record.site
        assert_nil ::PfAliasRepointed.find(record.id)[:site]
        assert_equal [%w[site email]], MaskedAttributes::AliasAccess.send(:declared_aliases, ::PfAliasRepointed) - [%w[id_value id]]
      ensure
        ::PfAliasRepointed.alias_attribute :site, :domain
      end

      test "a subclass that declares its parent's alias again is covered where Rails generated its methods" do
        record = record_of(::PfAliasRedeclaredChild, [::PfAliasRedeclaredParent, ::PfAliasRedeclaredChild])

        assert_nil record.mail

        record.mail = nil
        record.save!

        assert_equal ADDRESS, stored(record, 'email')
      end

      test "without Rails' registry of declared aliases, the aliases that differ from the superclass's count" do
        model = Struct.new(:attribute_aliases, :superclass)
        parent = model.new({ 'mail' => 'email', 'label' => 'name' }, nil)
        child = model.new({ 'mail' => 'email', 'label' => 'domain', 'site' => 'domain' }, parent)

        assert_equal [%w[label domain], %w[site domain]], MaskedAttributes::AliasAccess.send(:declared_aliases, child)
      end

      test 'an alias of a virtual attribute follows that attribute' do
        record = record_of(::PfAliasVirtual, [::PfAliasVirtual], nickname: { read_access: false })

        assert_equal 'Ace', record.nick, 'virtual masking is off: the getter is not masked'
        assert_nil record[:nick]

        record.nick = nil # the hidden value: a setter of a virtual attribute is not guarded, nor is its alias's

        assert_nil record.read_attribute_before_type_cast('nickname')

        record.nick = 'Ace'

        @config.mask_virtual_attributes = :auto
        ::PfAliasVirtual.pf_mask_virtual_readers(%w[nickname])

        assert_nil record.nickname
        assert_nil record.nick
        assert_not record.as_json(methods: [:nick]).key?('nick')

        @config.mask_virtual_attributes = false

        assert_equal 'Ace', record.nickname
        assert_equal 'Ace', record.nick, 'virtual masking switched off again: the wrapped getter no longer masks, nor does its alias'
      end

      # Listing an alias as a virtual field is the one way to give it a level
      # of its own; with virtual masking on, that level applies on top.
      test 'an alias the model lists as a virtual field is also held to that field while virtual masking is on' do
        record = record_of(::PfAliasOverridden, [::PfAliasOverridden], email: {}, mail: { read_access: false })

        assert_equal "<#{ADDRESS}>", record.mail

        @config.mask_virtual_attributes = :auto
        ::PfAliasOverridden.pf_mask_virtual_readers(%w[mail])

        assert_nil record.mail
        assert_equal ADDRESS, record.email
      end

      test 'explain reads an alias through the field of its column' do
        record = record_of(::PfConcernThenAlias)

        report = MaskedAttributes.explain(record, :mail)

        assert report[:field_configured]
        assert_equal false, report[:field_entry][:read_access]
        assert_nil report[:returned_value]
      end
    end

    # Where the concern puts its accessors decides which of a model's own
    # methods still run. A class that was loaded, or in use, before the concern
    # arrived must end up as a class loaded afterwards: its own methods, those
    # of the modules it includes and those of its ancestors answer first, and
    # reach the guarded value through `super`.
    class MaskedAccessorPlacementTest < ActiveSupport::TestCase
      include PfAliasTestSupport

      # In the order the concern must reach them: the parent first.
      FAMILY = [::PfVehicle, ::PfCar, ::PfTruck, ::PfPickup, ::PfVan].freeze

      # The same code without the concern, by model name (the subclasses that
      # are defined during the tests have none of their own).
      TWINS = { 'PfVehicle' => ::PfPlainVehicle, 'PfCar' => ::PfPlainCar, 'PfLateCar' => ::PfPlainCar,
                'PfTruck' => ::PfPlainTruck, 'PfPickup' => ::PfPlainPickup, 'PfLatePickup' => ::PfPlainPickup,
                'PfVan' => ::PfPlainVan, 'PfLateVan' => ::PfPlainVan, 'PfHolder' => ::PfPlainVehicle,
                'PfHeldGuarded' => ::PfPlainCar, 'PfHeldBystander' => ::PfPlainCar }.freeze

      setup do
        @config = PermissionForge.configuration
        @user = create_user
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @config.unconfigured_field_strategy = :block
      end

      # Rows for the family, which gives its parent the concern, and then its
      # subclasses that are defined only now: the lazy-loading order.
      def family
        protect(*FAMILY)
        late = [PfAliasCode.late(:PfLateCar, ::PfVehicle), PfAliasCode.late(:PfLatePickup, ::PfTruck),
                PfAliasCode.late(:PfLateVan, ::PfVehicle) { include PfAliasCode::Loud }]
        protect(*late)
        FAMILY + late
      end

      # Everything a record of `klass` answers, and what it stores when its
      # aliases and a column are written.
      def answers(klass)
        record = row(klass)
        read = %i[label mail title domain name email].index_with { |reader| record.public_send(reader) }
        read[:brackets] = [record[:label], record[:mail], record.read_attribute(:title)]
        read.merge(written: written(record))
      end

      def written(record)
        record.label = 'x'
        record.title = 'y'
        record.save!
        through_aliases = [stored(record, 'domain'), stored(record, 'name')]
        record.domain = 'z'
        record.save!
        through_aliases << stored(record, 'domain')
      end

      def assert_as_plain_rails(klass)
        Current.user = nil

        assert_equal answers(TWINS.fetch(klass.name)), answers(klass), klass.name
      end

      # The modules and classes a method is looked up in, the class itself
      # and its own generated modules named alike for every class.
      def lookup_order(klass)
        klass.ancestors.take_while { |mod| mod != ApplicationRecord }
             .map { |mod| mod.name.to_s.sub(/\A#{klass.name}(?=\z|::)/, 'Self') }
      end

      # Column methods of its own that Rails generated for `klass` and that its
      # parent's masked ones would be behind.
      def generated_copies(klass)
        klass.send(:generated_attribute_methods).instance_methods(false) & klass::MaskedAttributeReaders.instance_methods(false)
      end

      # --- a family that gets the concern on its parent ------------------------------

      test 'with no current user every class of the family answers and stores as its twin without the concern' do
        family.each { |klass| assert_as_plain_rails(klass) }
      end

      test "the parent's own reader and writer under an alias's name run for every subclass, on the guarded value" do
        family.each do |klass|
          Current.user = @user
          record = row(klass)

          assert_equal 'vehicle:acme.com', record.label, klass.name
          assert_equal 'm:', record.mail, klass.name
          assert_nil record[:mail], klass.name
          assert_equal MASK, record.title, klass.name

          record.label = 'x'
          record.save!

          assert_equal 'set:x', stored(record, 'domain'), klass.name
        end
      end

      test "a subclass's own column readers run, loaded before the concern or after, on the guarded value" do
        family
        [::PfTruck, ::PfPickup, ::PfLatePickup].each do |klass|
          Current.user = @user
          record = row(klass)

          assert_equal 'truck:acme.com', record.domain, klass.name
          assert_equal "truck:#{MASK}", record.name, klass.name
          assert_nil record.email, klass.name

          Current.user = nil

          assert_equal 'truck:Acme Corp', record.name, klass.name
        end
      end

      test 'a column reader from a module a subclass includes runs, loaded before the concern or after' do
        family
        [::PfVan, ::PfLateVan].each do |klass|
          Current.user = @user

          assert_equal 'ACME.COM', row(klass).domain, klass.name
          assert_nil row(klass).email, klass.name

          Current.user = nil

          assert_equal 'ACME.COM', row(klass).domain, klass.name
        end
      end

      test 'a subclass that was loaded or in use before the concern arrived is shaped as one loaded afterwards' do
        family

        assert_equal({ ::PfVehicle => true, ::PfCar => false, ::PfTruck => true, ::PfPickup => true, ::PfVan => true },
                     PF_ALIAS_FAMILY_GENERATED, 'what Rails had generated when the concern arrived')
        { ::PfCar => ::PfLateCar, ::PfPickup => ::PfLatePickup, ::PfVan => ::PfLateVan }.each do |early, late|
          assert_equal lookup_order(late), lookup_order(early)
          assert_empty generated_copies(early)
          assert_empty generated_copies(late)
        end
        assert_equal %w[Self Self::GeneratedAssociationMethods Self::GeneratedAttributeMethods PfVehicle::MaskedAttributeReaders PfVehicle],
                     lookup_order(::PfCar).first(5)
        assert_equal %w[PfVehicle::MaskedAliasAccessors PfVehicle::GeneratedAttributeMethods], lookup_order(::PfCar).last(2)
      end

      test 'the write-back guard holds for a subclass that was loaded or in use before the concern arrived' do
        family.each do |klass|
          Current.user = @user
          record = row(klass)
          hidden = record.email

          assert_nil hidden

          record.email = hidden
          record.title = MASK
          record.assign_attributes(mail: nil)
          record.save!

          assert_equal ADDRESS, stored(record, 'email'), klass.name
          assert_equal 'Acme Corp', stored(record, 'name'), klass.name
        end
      end

      test 'the family is a real single-table hierarchy' do
        family
        Current.user = @user
        record = row(::PfCar)

        assert_equal 'PfCar', record.type
        assert_instance_of ::PfCar, ::PfVehicle.find(record.id)
        assert_nil ::PfVehicle.find(record.id).email
        assert_equal [record.id], ::PfCar.where(id: record.id).pluck(:id)
      end

      test 'Rails dropping its attribute methods and generating them again changes nothing' do
        family.each do |klass|
          Current.user = @user
          record = row(klass)
          before = %i[email mail label name].map { |reader| record.public_send(reader) }

          klass.undefine_attribute_methods # what reset_column_information does; nothing is generated again yet

          assert_equal before, %i[email mail label name].map { |reader| record.public_send(reader) }, klass.name

          record.email = nil
          record.title = MASK
          record.label = 'window'
          record.save!

          assert_equal [ADDRESS, 'Acme Corp', 'set:window'], %w[email name domain].map { |column| stored(record, column) }, klass.name

          klass.reset_column_information

          assert_as_plain_rails(klass)
        end
      end

      # --- other orders ------------------------------------------------------------------

      test "a subclass whose attribute methods Rails had undefined when the concern arrived finds its parent's" do
        protect(::PfResetParent, ::PfResetChild)
        Current.user = @user
        record = row(::PfResetChild)

        assert_nil record.email
        assert_nil record.mail
        assert_equal MASK, record.name
        assert_empty generated_copies(::PfResetChild)

        record.name = MASK
        record.email = nil
        record.domain = 'new.example'
        record.save!

        assert_equal([ADDRESS, 'Acme Corp', 'new.example'], %w[email name domain].map { |column| stored(record, column) })
      end

      test 'the concern applied to the leaf first, then to its ancestors, guards every class' do
        protect(::PfLeafFirstLeaf, ::PfLeafFirstMiddle, ::PfLeafFirstRoot)
        [::PfLeafFirstRoot, ::PfLeafFirstMiddle, ::PfLeafFirstLeaf].each do |klass|
          Current.user = @user
          record = row(klass)

          assert_equal [nil, nil, MASK, 'acme.com'], [record.email, record.mail, record.name, record.domain], klass.name

          record.name = MASK
          record.mail = nil
          record.domain = 'new.example'
          record.save!

          assert_equal [ADDRESS, 'Acme Corp', 'new.example'], %w[email name domain].map { |column| stored(record, column) }, klass.name

          klass.undefine_attribute_methods

          assert_nil row(klass).mail, klass.name
        end
        Current.user = @user

        assert_equal MASK, row(::PfLeafFirstLeaf).title
        assert_operator ::PfLeafFirstLeaf.ancestors.index(::PfLeafFirstLeaf::MaskedAttributeReaders), :<,
                        ::PfLeafFirstLeaf.ancestors.index(::PfLeafFirstLeaf), 'the leaf has the concern in its own right'
      end

      # --- an alias declared by a parent that never gets the concern -------------------

      test "an alias its parent declares is guarded for the class with the concern, and the parent's own methods still run" do
        protect(::PfHeldGuarded)
        Current.user = @user
        record = row(::PfHeldGuarded)

        assert_equal 'm:', record.mail
        assert_nil record[:mail]
        assert_equal 'vehicle:acme.com', record.label
        assert_equal MASK, record.title

        record.label = 'x'
        record.title = MASK
        record.mail = nil
        record.save!

        assert_equal([ADDRESS, 'Acme Corp', 'set:x'], %w[email name domain].map { |column| stored(record, column) })

        assert_as_plain_rails(::PfHeldGuarded)
      end

      test 'that parent and its other subclasses answer as if the concern were nowhere' do
        protect(::PfHeldGuarded)
        row(::PfHeldGuarded).mail

        [::PfHolder, ::PfHeldBystander].each do |klass|
          assert_not_operator klass, :<, MaskedAttributes

          Current.user = @user

          assert_equal answers(TWINS.fetch(klass.name)), answers(klass), klass.name
          assert_as_plain_rails(klass)
        end

        [::PfHolder, ::PfPlainVehicle].each(&:reset_column_information)

        assert_as_plain_rails(::PfHeldBystander)
        assert_as_plain_rails(::PfHolder)

        partial = ::PfHeldBystander.select(:id).find(row(::PfHeldBystander).id)

        assert_raises(ActiveModel::MissingAttributeError) { partial.title }
        assert_raises(ActiveModel::MissingAttributeError) { ::PfPlainCar.select(:id).find(row(::PfPlainCar).id).title }
      end

      test 'an alias that parent points at another column afterwards is followed, for every one of its subclasses' do
        protect(::PfRepointGuarded)
        Current.user = @user
        guarded = row(::PfRepointGuarded)
        bystander = row(::PfRepointBystander)

        assert_equal %w[acme.com acme.com], [guarded.site, bystander.site]

        ::PfRepointHolder.alias_attribute :site, :email

        assert_nil guarded.site
        assert_equal ADDRESS, bystander.site

        guarded.site = nil
        bystander.site = 'new@acme.com'
        [guarded, bystander].each(&:save!)

        assert_equal [ADDRESS, 'new@acme.com'], [stored(guarded, 'email'), stored(bystander, 'email')]

        # Rails 7.1 calls the reader the model defines for the new target; later versions read the column.
        ::PfRepointHolder.alias_attribute :site, :name

        assert_equal MASK, guarded.site
        assert_equal(ActiveRecord.version < Gem::Version.new('7.2') ? 'held:Acme Corp' : 'Acme Corp', bystander.site)
      ensure
        ::PfRepointHolder.alias_attribute :site, :domain
      end

      # --- while it happens ----------------------------------------------------------------

      # Rows and permissions exist first and the engine does not apply the
      # concern, so that including it is all that happens while the threads
      # read. They read a loaded record and a warm permissions hash, in the
      # tenant of the main thread (acts_as_tenant keeps the test tenant per
      # thread; without it they would build a hash of their own, under
      # another cache key): nothing here touches the database off the main
      # thread.
      test 'records read on other threads while the concern is applied are never broken, and end up guarded' do
        @config.auto_apply_masked_attributes = false
        protect(::PfBusyParent, ::PfBusyChild)
        record = row(::PfBusyChild)
        user = @user.tap(&:permissions_hash)
        tenant = ActsAsTenant.test_tenant
        readers = [-> { record.email }, -> { record.mail }, -> { record.name }, -> { record[:email] }]
        allowed = [[ADDRESS, nil], [ADDRESS, nil], ['Acme Corp', MASK], [ADDRESS, nil]]
        raise 'the concern is there already' if ::PfBusyParent < MaskedAttributes

        main = Thread.current
        queried = []
        counting = ->(*, payload) { queried << payload[:sql] unless Thread.current == main }
        stop = false
        rounds = Array.new(4, 0) # full rounds of reads each thread has done
        seen = ActiveSupport::Notifications.subscribed(counting, 'sql.active_record') do
          threads = Array.new(4) do |index|
            Thread.new do
              Current.user = user
              ActsAsTenant.test_tenant = tenant
              read = Set.new
              until stop
                read << readers.map(&:call)
                rounds[index] += 1
              end
              read
            end
          end
          # Every thread is reading while the concern is applied, and reads a
          # whole round again once it is (no wall-clock sleep: wait for the rounds).
          wait = ->(needed) { Thread.pass until needed.call || !threads.all?(&:alive?) }
          wait.call(-> { rounds.all?(&:positive?) })
          ::PfBusyParent.include(MaskedAttributes)
          applied = rounds.dup
          wait.call(-> { rounds.each_with_index.all? { |count, index| count > applied[index] + 1 } })
          stop = true
          threads.flat_map { |thread| thread.value.to_a }.uniq
        end

        assert_empty queried
        seen.each { |values| values.each_with_index { |value, index| assert_includes allowed[index], value } }
        assert_includes seen, [nil, nil, MASK, nil]

        Current.user = user

        assert_equal [nil, nil, MASK, nil], readers.map(&:call)
      end

      # The same, one step at a time: at every event of the main thread while
      # it includes the concern (a point where another thread can be
      # scheduled), every way of reading a record answers either as without
      # the concern or as with it — never raises, never anything else.
      test 'at every step of applying the concern, a record answers as before or as after, and never raises' do
        @config.auto_apply_masked_attributes = false
        protect(::PfSteppedParent, ::PfSteppedChild)
        record = row(::PfSteppedChild)
        unread = row(::PfSteppedChild)
        Current.user = @user.tap(&:permissions_hash)
        raise 'the concern is there already' if ::PfSteppedParent < MaskedAttributes

        raw = { 'name' => 'Acme Corp', 'email' => ADDRESS }
        readers = {
          getter: [-> { record.name }, 'Acme Corp', MASK],
          hidden_getter: [-> { record.email }, ADDRESS, nil],
          alias: [-> { record.mail }, ADDRESS, nil],
          brackets: [-> { record[:email] }, ADDRESS, nil],
          read_attribute: [-> { record.read_attribute(:name) }, 'Acme Corp', MASK],
          attributes: [-> { record.attributes.slice('name', 'email') }, raw, { 'name' => MASK }],
          as_json: [-> { record.as_json(methods: [:mail]).slice('name', 'email', 'mail') },
                    raw.merge('mail' => ADDRESS), { 'name' => MASK }],
          unread_getter: [-> { unread.name }, 'Acme Corp', MASK]
        }
        wrong = stepping_through(-> { ::PfSteppedParent.include(MaskedAttributes) }) do |event|
          readers.filter_map do |reader, (read, *allowed)|
            value = begin
              read.call
            rescue StandardError => e
              e
            end
            "#{reader} answered #{value.inspect} at #{event}" unless allowed.include?(value)
          end
        end

        assert_empty wrong.first(10)
        assert_equal(readers.transform_values(&:last), readers.transform_values { |read, *| read.call })
      end

      private

      # Calls the block at every event of this thread while `work` runs (a
      # line, a call or a return, of Ruby or C), with tracing off while it
      # does. Returns everything the block returned, in one list.
      def stepping_through(work)
        main = Thread.current
        stepping = false
        results = []
        trace = TracePoint.new(:line, :call, :return, :c_call, :c_return, :b_call, :b_return) do |point|
          next if stepping || Thread.current != main

          stepping = true
          begin
            results.concat(yield("#{point.event} #{point.defined_class}##{point.method_id} #{point.path}:#{point.lineno}"))
          ensure
            stepping = false
          end
        end
        trace.enable { work.call }
        results
      end
    end
  end
end
