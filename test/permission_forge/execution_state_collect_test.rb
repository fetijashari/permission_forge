# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # A run completed inside a Cache::Failure.collect block (an in-process Rack
  # call through ActionDispatch::Executor inside the block) must not empty the
  # collector stack: that collect would miss its own failure and confirm a
  # user whose invalidation failed — the one slot where cleaning fails open.
  class ExecutionStateCollectTest < ActiveSupport::TestCase
    test 'a run completed inside a collect block keeps that collect\'s failures' do
      seen = []
      Thread.new do
        endpoint = ActionDispatch::Executor.new(->(_env) { [200, {}, ['ok']] }, Rails.application.executor)
        Rails.application.executor.wrap do
          collected = Cache::Failure.collect do
            _status, _headers, body = endpoint.call(Rack::MockRequest.env_for('/'))
            body.close
            Cache::Failure.report(operation: :invalidate, user_id: 9)
          end
          seen << collected.to_a.size << collected.confirmed([9])
        end
      end.join

      assert_equal [1, []], seen, 'the collect sees its own failure and confirms nobody'
    end
  end
end
