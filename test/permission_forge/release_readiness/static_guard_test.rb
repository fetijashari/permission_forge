# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/static_guard'

module PermissionForge
  module ReleaseReadiness
    # The shared scanner every static guard uses (test/support/static_guard.rb).
    class StaticGuardTest < ActiveSupport::TestCase
      test 'a comment never hits, in Ruby or ERB' do
        assert_equal '', StaticGuard.code_of('# x.to_sentence').strip
        assert_equal 'call ', StaticGuard.code_of('call # x.to_sentence')
        assert_no_match(/to_sentence/, StaticGuard.code_of('<%# names.to_sentence %>', erb: true))
      end

      test 'a string literal is blanked unless strings: :keep' do
        assert_no_match(/to_sentence/, StaticGuard.code_of("puts 'a.to_sentence'"))
        assert_match(/to_sentence/, StaticGuard.code_of("puts 'a.to_sentence'", strings: :keep))
      end

      test 'an interpolation is code, not a comment' do
        assert_match(/to_sentence/, StaticGuard.code_of("\"\#{names.to_sentence}\"", strings: :keep))
      end

      test 'canonical files and allowlisted lines are not hits; every hit names file and line' do
        globs = %w[lib/permission_forge/admin/list_sentence.rb]
        needle = /def self\.|module_function|class ListSentence|module ListSentence/

        all = StaticGuard.all_hits(globs: globs, needle: needle)
        assert all.any?, 'the fixture file must contain the needle'
        assert_match(%r{\Alib/permission_forge/admin/list_sentence\.rb:\d+ }, all.first.to_s)
        assert_empty StaticGuard.scan(globs: globs, needle: needle, canonical: globs)
        allowlist = all.map { |hit| [hit.file, Regexp.new(Regexp.escape(hit.line.strip)), 'fixture'] }
        assert_empty StaticGuard.scan(globs: globs, needle: needle, allowlist: allowlist)
      end

      test 'assert_allowlist_current fails on a stale entry and on an entry without a reason' do
        recorder = Class.new do
          attr_reader :failures_seen

          def initialize = @failures_seen = []
          def assert(value, message = nil) = (@failures_seen << message unless value)
        end
        globs = %w[lib/permission_forge/admin/list_sentence.rb]
        needle = /module|class/

        test_double = recorder.new
        StaticGuard.assert_allowlist_current(test_double, globs: globs, needle: needle,
                                                          allowlist: [[globs.first, /no such line at all/, 'gone']])
        assert(test_double.failures_seen.any? { |message| message.include?('stale allowlist entry') })

        test_double = recorder.new
        StaticGuard.assert_allowlist_current(test_double, globs: globs, needle: needle,
                                                          allowlist: [[globs.first, /module|class/, ' ']])
        assert(test_double.failures_seen.any? { |message| message.include?('give the allowlist entry a reason') })
      end
    end
  end
end
