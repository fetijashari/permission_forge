# frozen_string_literal: true

module PermissionForge
  # Helpers shared by the boot and masking-sync tests (minitest/mock is not
  # available under Minitest 6).
  module BootTestHelpers
    private

    # Replaces a singleton method of `object` for the block and restores the
    # original (with its visibility) afterwards. A method inherited by the
    # singleton class (e.g. from an extended module) comes back on its own.
    def with_singleton_method(object, name, implementation)
      owner = object.singleton_class
      own = owner.method_defined?(name, false) || owner.private_method_defined?(name, false)
      original = owner.instance_method(name) if own
      was_private = owner.private_method_defined?(name)
      owner.send(:remove_method, name) if own # no "method redefined" warning
      object.define_singleton_method(name, &implementation)
      yield
    ensure
      owner.send(:remove_method, name)
      if original
        owner.send(:define_method, name, original)
        owner.send(:private, name) if was_private
      end
    end

    # SQL statements the block runs, schema and transaction statements aside.
    def count_sql(&)
      count = 0
      counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
      count
    end

    # What the block writes to Rails.logger.
    def capture_rails_log
      output = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(output)
      yield
      output.string
    ensure
      Rails.logger = original
    end
  end
end
