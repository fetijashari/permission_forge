# frozen_string_literal: true

require 'test_helper'
require 'permission_forge/docs/configuration_reference'

module PermissionForge
  module Docs
    # docs/configuration.md's Option reference is generated from the code
    # (SettingsCatalog, Configuration.new, StrategyValues): the file in the
    # repository must be what the generator renders, every configuration
    # option must have an entry, and every entry a text.
    class ConfigurationReferenceTest < ActiveSupport::TestCase
      PATH = File.expand_path('../../../docs/configuration.md', __dir__)

      def document = @document ||= File.read(PATH)
      def reference(**) = ConfigurationReference.new(document: document, **)

      test 'the Option reference in docs/configuration.md is what the code generates' do
        rendered = reference.render
        # assert, not assert_equal: Minitest's diff of two 60 KB documents buried the summary.
        assert rendered == document, stale_message(rendered, document)
      end

      test 'regenerating is a no-op' do
        once = reference.render
        assert_equal once, ConfigurationReference.new(document: once).render
      end

      test 'every public writer of Configuration has an entry, in the order of the Settings page, and every entry is a writer' do
        writers = (Configuration.public_instance_methods - Object.public_instance_methods).grep(/\A\w+=\z/).map { |name| name.to_s.chomp('=') }
        headings = region[/.*/m].scan(/^#### (\w+)$/).flatten
        assert_equal writers.sort, headings.sort
        definitions = Admin::SettingsCatalog::DEFINITIONS
        catalog = Admin::SettingsCatalog::SECTIONS.flat_map { |section| definitions.select { |d| d.section == section }.map(&:key) }
        assert_equal catalog, headings.first(catalog.size), 'the catalog options come first, section by section as the Settings page shows them'
        assert_equal writers - catalog, headings.drop(catalog.size), 'the options the Settings page does not show follow'
      end

      test 'every entry has a default line and a text' do
        entries = region.split(/^#### /).drop(1)
        entries.each do |entry|
          key, body = entry.split("\n", 2)
          lines = body.strip.lines.map(&:chomp)
          assert_match ConfigurationReference::GENERATED_LINE, lines.first, "#{key}: the first line under the heading is the generated default"
          prose = lines.drop(1).join("\n").strip
          assert prose.present?, "#{key}: no description"
          assert_not_includes prose, ConfigurationReference::PLACEHOLDER, "#{key}: describe the option (the generator left a placeholder)"
        end
      end

      test 'the default line reads from Configuration.new and StrategyValues' do
        assert_includes region, "#### nil_user_strategy\n\n**Default:** `:bypass` Takes `:bypass`, `:raise` or `:deny` (or its String).\n"
        assert_includes region, "#### action_guard_nil_user_strategy\n\n**Default:** `nil` (the built-in behaviour) " \
                                "Takes `:bypass`, `:deny` or `:raise` (or its String), or nil.\n"
        assert_includes region, "#### cache_ttl\n\n**Default:** `3600`\n"
        assert_includes region, "#### user_list_resolver\n\n**Default:** `nil` (the built-in behaviour)\n"
        assert_includes region, "#### tenant_model\n\n**Default:** `nil` (off)\n"
        assert_includes region, "#### gdpr_field_patterns\n\n**Default:** `PermissionForge::Configuration::DEFAULT_GDPR_FIELD_PATTERNS`\n"
        assert_includes region, "#### nested_attributes_parent_fallback\n\n**Default:** `false`\n"
        assert_includes region, "#### current_user_resolver\n\n**Default:** the gem's own lambda\n"
      end

      # --- the guard bites ---------------------------------------------------------

      test 'a stale document is reported as a short summary, not the whole file' do
        stale = document.sub("#### cache_ttl\n\n**Default:** `3600`", "#### cache_ttl\n\n**Default:** `1800`")
        message = stale_message(document, stale)
        assert_operator message.bytesize, :<, 2_000, message
        assert_includes message, 'rake docs:configuration'
        assert_includes message, '1 line(s) differ'
        assert_includes message, '**Default:** `1800`'
      end

      test 'a default changed in Configuration makes the document stale' do
        changed = Configuration.new
        changed.nil_user_strategy = :deny
        assert reference(configuration: changed).stale?
        assert_includes reference(configuration: changed).render, "#### nil_user_strategy\n\n**Default:** `:deny` Takes"
      end

      test 'a hand-edited default line or heading is regenerated, the prose under it is kept' do
        edited = document.sub("#### cache_ttl\n\n**Default:** `3600`", "#### cache_ttl\n\n**Default:** `1800`")
        rendered = ConfigurationReference.new(document: edited).render
        assert_equal document, rendered
        reordered = document.sub("#### cache_ttl\n", "#### cache_ttl_renamed\n")
        rendered = ConfigurationReference.new(document: reordered).render
        assert_not_includes rendered, 'cache_ttl_renamed'
        assert_includes rendered, "#### cache_ttl\n\n**Default:** `3600`\n\n**Cache lifetime.**"
      end

      test 'an option with no text yet gets the Settings page text, one with neither a placeholder' do
        without = document.sub(/^#### cache_ttl\n\n\*\*Default:\*\* `3600`\n\n.*?(?=^#### )/m, "#### cache_ttl\n\n**Default:** `3600`\n\n")
        assert_includes ConfigurationReference.new(document: without).render,
                        "#### cache_ttl\n\n**Default:** `3600`\n\n**Cache lifetime.** How long computed permissions are kept."
        configuration = Class.new(Configuration) { attr_accessor :brand_new_option }.new
        rendered = reference(configuration: configuration).render
        assert_includes rendered, "#### brand_new_option\n\n**Default:** `nil`\n\n#{ConfigurationReference::PLACEHOLDER}"
      end

      private

      def region
        @region ||= document[/#{Regexp.escape(ConfigurationReference::START_MARK)}(.*)#{Regexp.escape(ConfigurationReference::END_MARK)}/m, 1] ||
                    flunk('docs/configuration.md has no option-reference markers')
      end

      # What a stale document reports: what to run, how many lines differ and the first few, each cut short.
      def stale_message(rendered, actual)
        generated = rendered.lines
        file = actual.lines
        differing = (0...[generated.size, file.size].max).reject { |index| generated[index] == file[index] }
        shown = differing.first(3).map do |index|
          "line #{index + 1}\n  generated: #{generated[index].to_s.truncate(200).inspect}\n  file:      #{file[index].to_s.truncate(200).inspect}"
        end
        "docs/configuration.md is stale: run `bundle exec rake docs:configuration` and commit the result.\n" \
          "#{differing.size} line(s) differ (generated #{generated.size} lines, file #{file.size}); the first:\n#{shown.join("\n")}"
      end
    end
  end
end
