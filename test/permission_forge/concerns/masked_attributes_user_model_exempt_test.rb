# frozen_string_literal: true

require 'test_helper'
require_relative '../sti_models'

module PermissionForge
  module Concerns
    # masked_attributes_nil_user_strategy = :hide (an explicit opt-in, in no
    # preset) hides every guarded attribute when nobody is signed in — except
    # on the user model (config.user_class and its subclasses): authentication reads
    # the user record before anyone is signed in (Devise's encrypted_password,
    # confirmation_token, the lockable counters). Other models keep :hide, and
    # a signed-in user is judged by their permissions as before.
    #
    # The user model here is PfStiBugTicket (never a Resource row named User:
    # that would mask the dummy's User for the rest of the process), so its
    # subclass PfStiUrgentBugTicket is a user model too and its base
    # PfStiTicket is not.
    class MaskedAttributesUserModelExemptTest < ActiveSupport::TestCase
      SECRET = 'crypted$2a$12$secret'

      setup do
        Current.user = nil
        set = create_permission_set(name: 'Ticket readers')
        tickets = create_resource(permission_set: set, name: 'PfStiTicket', read_access: true)
        create_resource_field(resource: tickets, name: 'title', label: 'Title', read_access: true)
        create_resource_field(resource: tickets, name: 'email', label: 'Email', read_access: true,
                              mask_access: true, mask_strategy: 'email')
        customers = create_resource(permission_set: set, name: 'Customer', read_access: true)
        create_resource_field(resource: customers, name: 'email', label: 'Email', read_access: true)
        @set = set

        PermissionForge.configuration.masked_attributes_nil_user_strategy = :hide
        PermissionForge.configuration.user_class = 'PfStiBugTicket'
        PermissionForge.without_permission_scope do
          @signing_in = PfStiBugTicket.create!(title: 'Ann', email: 'ann@example.test', secret: SECRET)
          @urgent = PfStiUrgentBugTicket.create!(title: 'Bob', email: 'bob@example.test', secret: SECRET)
          @base = PfStiTicket.create!(title: 'Cat', email: 'cat@example.test', secret: SECRET)
          @customer = Customer.create!(name: 'Acme', email: 'sales@acme.test')
        end
      end

      teardown { Current.user = nil }

      test ':hide hides with no user, so the exemption is what keeps sign-in working' do
        assert_equal :hide, PermissionForge.configuration.masked_attributes_nil_user_strategy
        assert MaskedAttributes.applied?(PfStiTicket)
      end

      test 'with nobody signed in the user model reads its stored values, as authentication needs' do
        assert_equal 'Ann', @signing_in.title
        assert_equal 'ann@example.test', @signing_in.email
        assert_equal SECRET, @signing_in.secret, 'an unconfigured column (encrypted_password, say) too'
        assert_equal SECRET, @signing_in[:secret]
        assert_equal SECRET, @signing_in.read_attribute(:secret)
        assert_equal 'ann@example.test', @signing_in.as_json['email']
        assert_equal SECRET, @signing_in.attributes['secret']
      end

      test 'a subclass of the user model is the user model' do
        assert_equal 'bob@example.test', @urgent.email
        assert_equal SECRET, @urgent.secret
      end

      test 'every other masked model still hides with no user' do
        assert_nil @base.email, 'the base class of the user model is not the user model'
        assert_nil @base.secret
        assert_equal %w[id], @base.as_json.keys
        assert_nil @customer.email
        assert_nil @customer.name
      end

      test 'a signed-in user is judged by their permissions on the user model, as before' do
        reader = create_user
        Current.user = reader # before the assignment: under nil_user_strategy :deny nobody signed in finds no user
        create_permission_set_user(user: reader, permission_set: @set)

        assert_equal 'Ann', @signing_in.title
        assert_equal 'a***@example.test', @signing_in.email
      end

      test 'explain names the exemption' do
        assert_equal true, MaskedAttributes.explain(@signing_in, :email)[:user_model_exempt]
        assert_equal false, MaskedAttributes.explain(@base, :email)[:user_model_exempt]
        decisions = capture_io_rows { MaskedAttributes.explain_all(@signing_in) }
        assert_equal :no_user_user_model_exempt, decisions['email']
        assert_equal :no_user_hidden, capture_io_rows { MaskedAttributes.explain_all(@base) }['email']
      end

      test 'under :bypass nothing changes for either' do
        PermissionForge.configuration.masked_attributes_nil_user_strategy = :bypass

        assert_equal 'ann@example.test', @signing_in.email
        assert_equal 'cat@example.test', @base.email
        assert_equal :no_user_bypassed, capture_io_rows { MaskedAttributes.explain_all(@signing_in) }['email']
      end

      test 'a user_class that names no class exempts nothing' do
        PermissionForge.configuration.user_class = 'NoSuchUserModel'

        assert_nil @signing_in.email
        assert_not PermissionForge.configuration.user_model_class?(PfStiBugTicket)
      end

      test 'user_model_class? is the configured class and its subclasses' do
        config = PermissionForge.configuration
        assert config.user_model_class?(PfStiBugTicket)
        assert config.user_model_class?(PfStiUrgentBugTicket)
        assert_not config.user_model_class?(PfStiTicket)
        assert_not config.user_model_class?(Customer)
        assert_not config.user_model_class?(nil)
      end

      # The answer is kept per user_class value and per class, and a guarded
      # read names its class: no constant lookup per read.
      test 'reads with nobody signed in look up no constant' do
        lookups = 0
        inflector = ActiveSupport::Inflector
        original = inflector.method(:safe_constantize)
        replace_singleton_method(inflector, :safe_constantize) { |name| (lookups += 1) && original.call(name) }

        [@signing_in.email, @base.email, @urgent.secret] # each class is asked once
        before = lookups
        5.times { [@signing_in.email, @base.email, @urgent.secret, @base.as_json] }
        assert_equal before, lookups

        PermissionForge.configuration.user_class = 'PfStiTicket'
        assert_equal 'cat@example.test', @base.email, 'a new user_class is resolved again'
      ensure
        replace_singleton_method(inflector, :safe_constantize, original) if original
      end

      private

      # explain_all prints its table; attribute => decision.
      def capture_io_rows(&)
        rows = nil
        capture_io { rows = yield }
        rows.to_h { |row| [row[:attribute].to_s, row[:decision]] }
      end
    end
  end
end
