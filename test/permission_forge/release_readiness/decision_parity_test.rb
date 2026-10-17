# frozen_string_literal: true

require 'test_helper'
require_relative '../field_variant_models'
require_relative '../../support/boot_test_helpers'

module PermissionForge
  module ReleaseReadiness
    # G5 — decision parity (plan-final.md §2 OD): two surfaces that answer
    # the same question must give the same answer, on fixtures, not by
    # reading the code. Each work package keeps its cases in its own file
    # under test/support/decision_parity/ — fields.rb (WP-8a: (a) the three
    # paths that create field rows, (b) the sensitive-column matcher, (g)
    # "readable in the clear"), rules.rb (WP-8b: (c)–(e), (h)–(j)) — and every
    # file reopens this class to add its tests, so a case is added without
    # touching another package's file. This file holds the shared helpers and
    # loads every part.
    class DecisionParityTest < ActiveSupport::TestCase
      include BootTestHelpers

      # Runs the block with `names` among the host's filter_parameters and
      # the integration on (SensitiveColumns then counts them as personal
      # data); puts both back.
      def with_filter_parameters(*names)
        config = Rails.application.config
        original = config.filter_parameters
        config.filter_parameters = original + names
        PermissionForge.configuration.filter_parameters_integration = true
        yield
      ensure
        config.filter_parameters = original
      end

      def parity_set(name, muting: false)
        create_permission_set(name: "#{name} #{SecureRandom.hex(3)}", is_muting: muting)
      end
    end
  end
end

Dir[File.expand_path('../../support/decision_parity/*.rb', __dir__)].each { |file| require file }
