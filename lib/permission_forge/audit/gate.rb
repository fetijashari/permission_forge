# frozen_string_literal: true

module PermissionForge
  module Audit
    # Whether a runtime event could be stored or heard right now — asked on
    # the hottest paths of the gem (every attribute read under
    # MaskedAttributes asks it for field.access), so the answer is kept and
    # only worked out again when something it depends on changed. The
    # generation is bumped by:
    #
    #   - the writers of the options that decide it (audit_runtime_events,
    #     on_field_filtered, on_rule_bypass, audit_log_subscriber);
    #   - every subscribe and unsubscribe: they go through
    #     ActiveSupport::Notifications::Fanout#clear_cache (FanoutHook), also
    #     for a pattern subscriber;
    #   - a new notifier (ActiveSupport::Notifications.notifier=, NotifierHook);
    #   - a new Configuration (PermissionForge.reset!, Configuration.new). A
    #     configuration object put back in place past PermissionForge's API
    #     (instance_variable_set with one made earlier) is not noticed.
    #
    # The answer is a superset: a subscriber of the host that says it is
    # silenced still counts (it may change its mind without telling), and
    # Audit.instrument asks the notifier again before it builds anything. The
    # gem's own subscribers (Subscribers::Base) are silenced by their option,
    # whose writer bumps the generation, so they count only while it is set.
    # Where the notifier is not a Fanout with the hook, nothing is kept and
    # the notifier is asked every time.
    #
    #   Gate.for('field.access').open? # => false
    #
    # @api private
    class Gate
      # Bumps the generation whenever ActiveSupport changes who listens.
      module FanoutHook
        def clear_cache(...)
          super
        ensure
          PermissionForge::Audit::Gate.changed!
        end
      end

      # Bumps the generation when the notifier is replaced.
      module NotifierHook
        def notifier=(notifier)
          super
        ensure
          PermissionForge::Audit::Gate.changed!
        end
      end

      MUTEX = Mutex.new
      # The generation, read on every check: an Array element in a constant
      # is the cheapest read Ruby has.
      GENERATION = [0] # rubocop:disable Style/MutableConstant -- bumped in place by changed!

      @gates = {}

      class << self
        # @return [Integer] bumped by every change the answers depend on
        def generation = GENERATION[0]

        # @param event [String] an access event of the catalogue
        # @return [Gate]
        def for(event)
          @gates[event] || MUTEX.synchronize { @gates[event.to_s] ||= new(EventCatalog.fetch(event).name) }
        end

        # Something an answer depends on changed: every gate works it out again.
        def changed!
          MUTEX.synchronize { GENERATION[0] += 1 }
        end

        # Hooks the generation to ActiveSupport's subscriptions and notifier
        # (once; Audit.install!). Without the hooks nothing is kept.
        def install!
          fanout = ActiveSupport::Notifications::Fanout
          fanout.prepend(FanoutHook) if fanout.method_defined?(:clear_cache) && !(fanout <= FanoutHook)
          notifications = ActiveSupport::Notifications.singleton_class
          notifications.prepend(NotifierHook) unless notifications <= NotifierHook
          changed!
        end

        # Whether answers can be kept for this notifier.
        def tracking?(notifier)
          notifier.is_a?(FanoutHook) && ActiveSupport::Notifications.singleton_class <= NotifierHook
        end
      end

      # @param name [String] a registered access event
      def initialize(name)
        @name = name
        @snapshot = nil
      end

      # The kept answer is one frozen Array [generation, answer], replaced
      # whole: a reader on another thread sees an old answer or a new one,
      # never half of each.
      #
      # @return [Boolean] whether the event's group is stored or anyone may listen
      def open?
        snapshot = @snapshot
        return snapshot[1] if snapshot && snapshot[0] == GENERATION[0]

        refresh[1]
      end

      # The gem's own subscribers that take a light payload, when they are
      # the only ones that hear the event and its group is not stored: the
      # legacy hooks alone. Audit.instrument then hands them the payload
      # without building an event (no Recorder, no notification) — a hook set
      # for years must not cost what a full audit event costs. nil otherwise,
      # and wherever nothing is kept (no tracking).
      #
      # @return [Array<Subscribers::Base>, nil]
      def direct_listeners
        snapshot = @snapshot
        return snapshot[2] if snapshot && snapshot[0] == GENERATION[0]

        refresh[2]
      end

      private

      # The generation is read before the answer is worked out: a change made
      # meanwhile leaves a snapshot that is already out of date.
      #
      # @return [Array(Integer, Boolean, Array|nil)]
      def refresh
        generation = GENERATION[0]
        notifier = ActiveSupport::Notifications.notifier
        entry = EventCatalog.fetch(@name)
        stored = PermissionForge.configuration.store_runtime_group?(entry.runtime_group)
        listeners = heard_by(notifier, entry.notification)
        tracking = Gate.tracking?(notifier)
        snapshot = [generation, stored || !listeners.empty?, (direct_of(listeners) if tracking && !stored)].freeze
        @snapshot = (snapshot if tracking)
        snapshot
      end

      # What hears the notification: a delegate per listener (the listener
      # itself when it has none); [:unknown] when the notifier cannot say.
      def heard_by(notifier, notification)
        unless notifier.respond_to?(:all_listeners_for)
          return notifier.listening?(notification) ? [:unknown] : []
        end

        notifier.all_listeners_for(notification).filter_map do |listener|
          delegate = listener.respond_to?(:delegate) ? listener.delegate : listener
          delegate if counts?(delegate, notification)
        end
      end

      def counts?(delegate, notification)
        return true unless delegate.is_a?(Subscribers::Base)

        !delegate.silenced?(notification)
      end

      def direct_of(listeners)
        return if listeners.empty?
        return unless listeners.all? { |delegate| delegate.is_a?(Subscribers::Base) && delegate.light? }

        listeners.freeze
      end
    end
  end
end
