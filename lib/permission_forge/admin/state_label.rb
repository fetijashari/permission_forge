# frozen_string_literal: true

module PermissionForge
  module Admin
    # The one registry of the words and glyphs of every state the admin shows:
    # a field's configured level, an effective outcome, a CRUD cell, an action
    # state, a lock and an actor kind. A state is a [kind, state] pair; its
    # word is the locale key `ui.states.<kind>.<state>` and its glyph is
    # here, so a page never pairs a glyph with a word of its own (R4 #52:
    # "⊘ Hidden by muting" in one place, "∅ Hidden" for the same field in the
    # next). The helpers that draw a state (pf_state_badge, pf_state_word,
    # pf_level_badge, pf_state_cell, pf_lock_badge, ...) read it; no template
    # looks a state key up itself (release_readiness/state_key_guard_test.rb),
    # and two keys with the same English word in the label namespaces fail
    # i18n_test.rb.
    #
    # Two kinds keep their words where they were until the 0.16 merge
    # (NAMESPACES): the CRUD cell (shared.crud_cell) and the action states
    # (resource_actions.states). A state worded by another kind's key says so
    # in SHARED (one word, one key).
    #
    #   StateLabel.for(:field_level, 'masked').to_s  # => "•• Masked"
    #   StateLabel.word(:actor, :unknown)            # => "Unknown"
    #
    # @api private
    module StateLabel
      # kind => { state => glyph }. A kind whose states have no glyph of their
      # own (a lock draws an icon, an actor is a name) maps them to nil.
      GLYPHS = {
        field_level: { 'hidden' => '∅', 'masked' => '••', 'read' => '◉', 'edit' => '✎',
                       'leave' => '–', 'mask' => '••', 'hide' => '⊘', 'none' => '–' },
        effective: { 'granted' => '✓', 'blocked' => '⊘', 'none' => '–', 'hidden_by_muting' => '⊘' },
        crud: { 'allowed' => '✓', 'no' => '–', 'muted' => '⊘', 'unchanged' => '–', 'needs_read' => '–' },
        action: { 'permitted' => '✓', 'not_permitted' => '–', 'blocked' => '⊘', 'unchanged' => '–', 'none' => '–' },
        lock: { 'locked' => nil },
        actor: { 'api' => nil, 'basic_auth' => nil, 'system' => nil, 'unknown' => nil, 'user' => nil }
      }.freeze

      # Kinds whose words stay in their own namespace until 0.16 (allow-listed
      # in i18n_test.rb's label lint).
      NAMESPACES = { crud: 'permission_forge.shared.crud_cell', action: 'permission_forge.resource_actions.states' }.freeze
      # Locale keys under a namespace that are not the state's own name.
      KEY_NAMES = { [:crud, 'needs_read'] => 'needs_read_short' }.freeze
      # A state worded by another kind's key: an action no set configures is
      # "Not configured", the field level's word.
      SHARED = { [:action, 'none'] => [:field_level, 'none'] }.freeze

      # One state: its glyph (nil when the kind has none) and its word.
      Label = Data.define(:kind, :state, :glyph, :word) do
        # "glyph word", or the word alone.
        def to_s = glyph ? "#{glyph} #{word}" : word
      end

      module_function

      # @param kind [Symbol] one of GLYPHS' kinds
      # @param state [String, Symbol]
      # @param default [String, nil] the word for a state the registry does
      #   not have (an actor type outside the catalogue is shown as stored);
      #   without it such a state raises
      # @return [Label]
      # @raise [ArgumentError] an unknown kind, or an unknown state without `default`
      def for(kind, state, default: nil)
        kind = kind.to_sym
        state = state.to_s
        glyphs = GLYPHS.fetch(kind) { raise ArgumentError, "Unknown state kind: #{kind.inspect}" }
        unless glyphs.key?(state)
          raise ArgumentError, "Unknown #{kind} state: #{state.inspect}" if default.nil?

          return Label.new(kind: kind, state: state, glyph: nil, word: default.to_s)
        end

        Label.new(kind: kind, state: state, glyph: glyphs[state], word: I18n.t(key(kind, state)))
      end

      # @return [String] the state's word, in the current locale
      def word(kind, state, default: nil) = self.for(kind, state, default: default).word

      # @return [String, nil] the state's glyph
      def glyph(kind, state) = GLYPHS.fetch(kind.to_sym).fetch(state.to_s)

      # @return [String] the locale key of the state's word
      def key(kind, state)
        kind = kind.to_sym
        state = state.to_s
        shared = SHARED[[kind, state]]
        return key(*shared) if shared

        namespace = NAMESPACES.fetch(kind) { "permission_forge.ui.states.#{kind}" }
        "#{namespace}.#{KEY_NAMES.fetch([kind, state], state)}"
      end

      # @return [Array<Array(Symbol, String)>] every [kind, state] of the registry
      def states = GLYPHS.flat_map { |kind, glyphs| glyphs.keys.map { |state| [kind, state] } }
    end
  end
end
