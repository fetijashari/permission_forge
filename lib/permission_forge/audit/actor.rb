# frozen_string_literal: true

module PermissionForge
  module Audit
    # Who did it, as stored on an event: the type (user, api, basic_auth,
    # system, unknown), the id as a string (bigint and UUID keys both fit) and
    # a label — the person's name as it was at the time.
    #
    # Resolution order (Actor.current): the actor in the audit context (an
    # explicit `PermissionForge.with_audit_actor` block, or the request
    # context the controllers set), then `PermissionForge.current_user`,
    # otherwise unknown.
    #
    # @api public
    class Actor
      TYPES = %w[user api basic_auth system unknown].freeze

      # The actor's type (`user`, `system`, `unknown`, ...), id and display label, as stored on the event.
      attr_reader :type, :id, :label

      # The class of the user object the actor was made from (for_user), nil
      # for an actor given as a Hash or built by hand. Not part of equality:
      # it says whether the id is a key of config.audit_user_class
      # (HasAuditTrail stamps created_by / updated_by only then).
      attr_reader :user_class

      # @raise [ArgumentError] for a type outside TYPES
      def initialize(type:, id: nil, label: nil, user_class: nil)
        type = type.to_s
        raise ArgumentError, "audit actor type must be one of #{TYPES.join(', ')} (got #{type.inspect})" unless TYPES.include?(type)

        @type = type
        @id = id&.to_s
        @label = label.presence&.to_s
        @user_class = user_class
        freeze
      end

      class << self
        # @return [Actor] never nil
        def current
          Context[:actor] || from_current_user || unknown
        end

        # @param user [Object] a host user (anything with an id)
        # @param label [String, nil] overrides the name snapshot
        # @param type [String] 'user' unless the user acts as an API principal
        def for_user(user, label: nil, type: 'user')
          new(type: type, id: user.id, label: label || label_for(user), user_class: record_class_of(user))
        end

        # The class of the record behind a decorated user (SimpleDelegator /
        # Delegator, Draper), so a host's decorated current_user still stamps.
        def record_class_of(user)
          inner = user
          3.times do
            if inner.respond_to?(:__getobj__) then inner = inner.__getobj__
            elsif inner.respond_to?(:decorated?) && inner.respond_to?(:object) && inner.decorated? then inner = inner.object
            else break
            end
          end
          inner.class
        end

        # @return [Actor] the actor used when nothing identifies who acted
        def unknown
          new(type: 'unknown')
        end

        # @param label [String] what ran (a job, a rake task)
        # @return [Actor] a `system` actor
        def system(label)
          new(type: 'system', label: label)
        end

        # An Actor, a Hash { type:, id:, label: }, a user, or nil.
        #
        # @return [Actor, nil]
        def coerce(value)
          case value
          when nil then nil
          when Actor then value
          when Hash then new(**value.symbolize_keys.slice(:type, :id, :label))
          else for_user(value)
          end
        end

        # The name snapshot for a user: config.user_label_formatter, else the
        # same readers the admin screens use (Admin::PersonLabel).
        def label_for(user)
          PermissionForge::Admin::PersonLabel.new(user).name
        end

        private

        def from_current_user
          user = resolve_current_user
          for_user(user) if user
        end

        # A current_user_resolver that raises (a Current attribute reset, a
        # session store that is down) must not turn every change into an
        # error: the actor is unknown and the failure is reported
        # (config.audit_hook_failure_strategy; :raise raises). A user it
        # returns that cannot be read is a failure of the event itself.
        def resolve_current_user
          PermissionForge.current_user
        rescue StandardError => e
          Failure.handle(e, strategy: PermissionForge.configuration.audit_hook_failure_strategy, operation: :actor)
          nil
        end
      end

      # Whether the actor is a record of `klass` (or a subclass): made from a
      # user object of that class, not merely carrying an id.
      #
      # @param klass [Class, nil]
      def user_of?(klass)
        !klass.nil? && type == 'user' && !id.nil? && user_class.is_a?(Class) && user_class <= klass
      end

      # The three actor columns of an event.
      def to_columns
        { actor_type: type, actor_id: id, actor_label: label }
      end

      # [type, id, label]
      def to_a
        [type, id, label]
      end

      # Two actors are equal when their type, id and label are.
      def ==(other)
        other.is_a?(Actor) && to_a == other.to_a
      end
      alias eql? ==

      # @return [Integer] consistent with {#==}
      def hash
        to_a.hash
      end
    end
  end
end
