# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # PermissionForge.deprecator: the one channel for renamed or removed public
  # API, governed by the host's deprecation settings.
  class DeprecationTest < ActiveSupport::TestCase
    setup do
      @deprecator = PermissionForge.deprecator
      @saved = { behavior: @deprecator.behavior, silenced: @deprecator.silenced, debug: @deprecator.debug }
      @warnings = []
      @deprecator.behavior = ->(message, *) { @warnings << message }
    end

    teardown do
      @deprecator.behavior = @saved[:behavior]
      @deprecator.silenced = @saved[:silenced]
      @deprecator.debug = @saved[:debug]
    end

    def unique_message = "pf_deprecation_test #{SecureRandom.hex(4)} is deprecated"

    test 'one ActiveSupport::Deprecation named for the gem, whose horizon lies ahead of the version' do
      assert_kind_of ActiveSupport::Deprecation, @deprecator
      assert_same @deprecator, Deprecation.deprecator
      assert_equal 'PermissionForge', @deprecator.gem_name
      assert_equal Deprecation::HORIZON, @deprecator.deprecation_horizon
      # Reaching the horizon fails here: remove what was deprecated, then move it.
      assert_operator Gem::Version.new(VERSION), :<, Gem::Version.new(Deprecation::HORIZON)
    end

    test 'it is registered with the application deprecators' do
      assert_same @deprecator, Rails.application.deprecators[:permission_forge]
    end

    test 'the message names the gem and the version that removes it' do
      Deprecation.warn("#{unique_message}; use new_option")

      assert_equal 1, @warnings.size
      assert_match(/; use new_option\. PermissionForge #{Regexp.escape(Deprecation::HORIZON)} removes it\./, @warnings.first)
    end

    test 'Deprecation.warn warns once per key in a process' do
      message = unique_message
      3.times { Deprecation.warn(message) }
      Deprecation.warn('another wording', key: message)

      assert_equal 1, @warnings.size
      Deprecation.warn(unique_message)
      assert_equal 2, @warnings.size, 'a different key warns'
    end

    test 'a host that silences deprecations hears nothing, and the warning comes once it no longer does' do
      message = unique_message
      Rails.application.deprecators.silence { Deprecation.warn(message) }
      assert_empty @warnings

      Deprecation.warn(message)
      assert_equal 1, @warnings.size
    end

    # The application's collection sets the behavior of every registered
    # deprecator, as config.active_support.deprecation does at boot. A fresh
    # collection, so Rails' own deprecators are left alone.
    test 'a host that raises on deprecations gets an error on every call' do
      deprecators = ActiveSupport::Deprecation::Deprecators.new
      deprecators[:permission_forge] = @deprecator
      deprecators.behavior = :raise
      message = unique_message

      2.times { assert_raises(ActiveSupport::DeprecationException) { Deprecation.warn(message) } }
    end

    test 'a host behavior set before the gem registers applies to it too' do
      deprecators = ActiveSupport::Deprecation::Deprecators.new
      deprecators.behavior = :silence
      deprecators[:permission_forge] = @deprecator

      assert_nothing_raised { @deprecator.warn('quiet') }
      assert_empty @warnings
    end

    test 'reset! forgets which keys warned' do
      message = unique_message
      Deprecation.warn(message)
      Deprecation.reset!
      Deprecation.warn(message)

      assert_equal 2, @warnings.size
    end

    test 'register leaves an application without deprecators alone' do
      assert_nothing_raised { Deprecation.register(Object.new) }
    end

    # The convention for a renamed option or method (CONTRIBUTING / CLAUDE.md):
    # the old name keeps working, through the deprecator, for a minor version.
    # The old name calls the new one (alias_method would skip the writers
    # Configuration prepends: validation and the preset's bookkeeping).
    test 'a renamed option keeps its old name working with a warning' do
      settings = Class.new do
        attr_accessor :new_name

        def old_name = new_name

        def old_name=(value)
          self.new_name = value
        end

        PermissionForge.deprecator.deprecate_methods(self, old_name: :new_name, 'old_name=': :'new_name=')
      end.new

      settings.old_name = :value
      assert_equal :value, settings.new_name
      assert_equal :value, settings.old_name
      assert_equal 2, @warnings.size
      horizon = Regexp.escape(Deprecation::HORIZON)
      assert_match(/old_name= is deprecated and will be removed from PermissionForge #{horizon} \(use new_name= instead\)/, @warnings.first)
    end
  end
end
