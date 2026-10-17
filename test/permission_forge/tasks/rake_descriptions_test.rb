# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/rake_tasks'
require_relative '../../support/static_guard'

module PermissionForge
  module Tasks
    # Every task's `desc` survives `rake -T` whole, and names what the task
    # reads from the environment. Rake shows the first sentence of a
    # description (up to a full stop after a word, so "Art. 17" cuts it at
    # "Art") in the width that is left after the longest task name: a first
    # sentence of at most MAX_FIRST_SENTENCE characters with no abbreviation
    # and balanced parentheses, and every ENV variable the task's body reads
    # (RakeAudit reads ACTOR and REASON for the tasks it wraps) named in the
    # full description.
    class RakeDescriptionsTest < ActiveSupport::TestCase
      MAX_FIRST_SENTENCE = 100
      ABBREVIATION = /\b(Art|No|etc|e\.g|i\.e|cf|vs|approx|incl)\z/i
      ENV_READ = RakeTasks::ENV_READ

      def self.tasks = RakeTasks.tasks

      def self.env_keys_read(task) = RakeTasks.env_keys_read(RakeTasks.body_of(task))

      test 'the gem defines the tasks this lint knows, each with a description' do
        names = self.class.tasks.map(&:name)

        assert_equal %w[permission_forge:audit permission_forge:audit_events:purge permission_forge:audit_masks
                        permission_forge:cache:clear permission_forge:cleanup_expired_assignments permission_forge:erasure
                        permission_forge:expired_assignments permission_forge:rls:remove permission_forge:rls:status
                        permission_forge:rls:sync permission_forge:stale_assignments], names
        self.class.tasks.each { |task| assert task.comment.present?, "#{task.name} has no desc" }
      end

      RakeTasks.tasks.each do |task|
        test "#{task.name}: the first sentence shows whole in rake -T" do
          first = task.comment

          assert_operator first.length, :<=, MAX_FIRST_SENTENCE, "#{first.inspect} (#{first.length} chars)"
          assert_equal first.count('('), first.count(')'), "#{first.inspect} is cut inside a parenthesis"
          assert_no_match ABBREVIATION, first, "#{first.inspect} is cut at an abbreviation"
          assert task.full_comment.start_with?(first), 'the first sentence opens the description'
        end

        test "#{task.name}: the description names every ENV variable the task reads" do
          keys = self.class.env_keys_read(task)
          missing = keys.reject { |key| task.full_comment.match?(/\b#{key}\b/) }

          assert_empty missing, "#{task.name} reads #{missing.join(', ')} but its desc does not say so: #{task.full_comment.inspect}"
        end
      end

      test 'the ENV scan sees every way the tasks read a variable, and the body ends at the task' do
        assert_equal %w[DRY_RUN], "ENV.fetch('DRY_RUN', 'true')".scan(ENV_READ).flatten
        assert_equal %w[USER_ID], "ENV['USER_ID']".scan(ENV_READ).flatten
        assert_equal %w[FORMAT], "ENV.key?('FORMAT')".scan(ENV_READ).flatten
        erasure = RakeTasks.body_of(RakeTasks.application['permission_forge:erasure'])
        assert_match(/\A\s*task erasure:/, erasure)
        assert_match(/\n\s*end\n\z/, erasure)
        assert_no_match(/task stale_assignments/, erasure)
        assert_includes self.class.env_keys_read(RakeTasks.application['permission_forge:erasure']), 'ACTOR'
      end

      # Task.new builds a task without registering it: nothing to clean up.
      test 'negative fixture: a cut or over-long first sentence fails the lint' do
        cut = Rake::Task.new('permission_forge:fixture_cut', RakeTasks.application)
        cut.add_description('Erase a person (GDPR Art. 17) and more. ACTOR= names who ran it.')
        long = Rake::Task.new('permission_forge:fixture_long', RakeTasks.application)
        long.add_description("#{'Remove every expired assignment of every person in every tenant ' * 2}now")

        assert_equal 'Erase a person (GDPR Art', cut.comment
        assert_match ABBREVIATION, cut.comment
        assert_operator cut.comment.count('('), :>, cut.comment.count(')')
        assert_operator long.comment.length, :>, MAX_FIRST_SENTENCE
        assert_not RakeTasks.application.lookup('permission_forge:fixture_cut')
      end
    end
  end
end
