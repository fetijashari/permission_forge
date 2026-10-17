# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/static_guard'

module PermissionForge
  module ReleaseReadiness
    # A state is worded in one place: Admin::StateLabel (the registry of
    # ui.states.<kind>.<state>, glyph and word together) and the helpers
    # that draw it (pf_state_badge, pf_state_word, pf_level_badge,
    # pf_state_cell, pf_lock_badge, ...). No template looks a state key up
    # itself: neither by its full name (`t('permission_forge.ui.levels.hidden')`)
    # nor by a lazy key that lands in a state namespace (`t('.muted')` in
    # shared/_crud_cell resolves to shared.crud_cell.muted). A template that
    # did would be a second rendering of the state, free to drift (R4 #52:
    # "⊘ Hidden by muting" on one page, "∅ Hidden" on the next).
    #
    # The full-name scan also covers the helpers, the controllers and the
    # admin read models (review R4 P2-2): a helper that looked a state key
    # up would be the same second rendering. Admin::StateLabel is the one
    # file that names the namespaces (CANONICAL).
    class StateKeyGuardTest < ActiveSupport::TestCase
      GLOBS = %w[app/views/**/*.erb].freeze
      CODE_GLOBS = %w[app/views/**/*.erb app/helpers/**/*.rb app/controllers/**/*.rb lib/permission_forge/admin/**/*.rb].freeze
      CANONICAL = %w[lib/permission_forge/admin/state_label.rb].freeze
      NAMESPACES = %w[ui.levels ui.states shared.crud_cell resource_actions.states].freeze
      NEEDLE = /\b(?:#{NAMESPACES.map { |namespace| Regexp.escape(namespace) }.join('|')})\b/
      LAZY_KEY = /\bt\(\s*['"](\.[\w.]+)['"]/

      # The lazy scope Rails gives a template's `t('.key')`:
      # app/views/permission_forge/shared/_crud_cell.html.erb → permission_forge.shared.crud_cell
      def self.lazy_scope(file)
        file.delete_prefix('app/views/').sub(/\..*\z/, '').split('/').map { |part| part.delete_prefix('_') }.join('.')
      end

      # [file:line key] for every lazy key of a template that lands in a state namespace.
      def self.lazy_hits(files)
        files.flat_map do |path|
          lazy_hits_in(Pathname(path).relative_path_from(StaticGuard::ROOT).to_s, File.readlines(path))
        end
      end

      def self.lazy_hits_in(file, lines)
        scope = lazy_scope(file)
        lines.each_with_index.flat_map do |line, index|
          StaticGuard.code_of(line, erb: true, strings: :keep).scan(LAZY_KEY).flatten.filter_map do |key|
            full = "#{scope}#{key}"
            "#{file}:#{index + 1} #{full}" if NAMESPACES.any? { |namespace| full.start_with?("permission_forge.#{namespace}.") }
          end
        end
      end

      test 'no template, helper, controller or admin read model names a state key: states render through Admin::StateLabel' do
        hits = StaticGuard.scan(globs: CODE_GLOBS, needle: NEEDLE, canonical: CANONICAL, strings: :keep)

        assert_empty hits.map(&:to_s), 'render the state with pf_state_badge / pf_state_word (Admin::StateLabel)'
      end

      test 'no template reaches a state key through a lazy lookup' do
        hits = self.class.lazy_hits(StaticGuard.files(GLOBS))

        assert_empty hits, 'render the state with pf_state_badge / pf_state_word (Admin::StateLabel)'
      end

      # Negative fixtures: the needle and the lazy-key scan bite.
      test 'a state key in a template is a hit, in a comment it is not (negative fixture)' do
        line = %(<span><%= t('permission_forge.ui.levels.masked') %></span>)

        assert_match NEEDLE, StaticGuard.code_of(line, erb: true, strings: :keep)
        assert_no_match NEEDLE, StaticGuard.code_of("<%# #{line} %>", erb: true, strings: :keep)
        crud_cell = 'app/views/permission_forge/shared/_crud_cell.html.erb'
        assert_equal 'permission_forge.shared.crud_cell', self.class.lazy_scope(crud_cell)
        assert_equal ["#{crud_cell}:1 permission_forge.shared.crud_cell.muted"],
                     self.class.lazy_hits_in(crud_cell, [%(<span><%= t('.muted') %></span>)])
        assert_empty self.class.lazy_hits_in(crud_cell, [%(<%# t('.muted') %>)])
        assert_empty self.class.lazy_hits_in('app/views/permission_forge/home/index.html.erb', [%(<%= t('.title') %>)])
        assert_match NEEDLE, StaticGuard.code_of(%(t("permission_forge.ui.states.field_level.\#{level}")), strings: :keep)
        assert(StaticGuard.all_hits(globs: CANONICAL, needle: NEEDLE, strings: :keep).any?, 'the canonical file names the namespaces')
      end
    end
  end
end
