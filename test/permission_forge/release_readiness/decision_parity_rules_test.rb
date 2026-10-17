# frozen_string_literal: true

# G5 parity, the WP-8b parts (rules, locks, assignments): the test class lives
# in test/support/decision_parity/rules.rb, so a loader that requires every
# file under that directory (decision_parity_test.rb) runs it once too.
require_relative '../../support/decision_parity/rules'
