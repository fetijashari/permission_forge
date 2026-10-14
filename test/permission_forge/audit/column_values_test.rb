# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Audit
    # Every string column of an event is cleaned once, where every event
    # passes (Recorder): valid UTF-8, one line, no control characters, at
    # most 255 characters — whoever supplied it.
    class ColumnValuesTest < ActiveSupport::TestCase
      test 'line breaks become spaces, NUL and other control characters go, the rest stays' do
        assert_equal 'a b c d', ColumnValues.value("a\nb\rc\td")
        assert_equal 'abc[31m', ColumnValues.value("a\u0000b\u007Fc\e[31m")
        assert_equal 'x y', ColumnValues.value("x\u2028y")
        assert_equal 'aç', ColumnValues.value("a\u0080ç")
        assert_equal 'Ünïcode ✓', ColumnValues.value('Ünïcode ✓')
      end

      test 'invalid UTF-8 is replaced, other encodings are converted' do
        assert ColumnValues.value((+"ab\xFFcd").force_encoding(Encoding::BINARY)).valid_encoding?
        assert_equal 'é', ColumnValues.value('é'.encode(Encoding::ISO_8859_1))
      end

      test 'at most 255 characters; non-strings untouched' do
        assert_equal 255, ColumnValues.value('é' * 600).length
        assert_equal 42, ColumnValues.value(42)
        assert_nil ColumnValues.value(nil)
      end

      test 'clean touches only the listed columns' do
        row = ColumnValues.clean(reason: "a\nb", data: { 'k' => "a\nb" }, permission_set_id: 5)

        assert_equal({ reason: 'a b', data: { 'k' => "a\nb" }, permission_set_id: 5 }, row)
      end

      test 'a stored event has every client- or host-supplied string cleaned and capped' do
        long = 'L' * 400
        Context.with(request_id: "req\n#{long}", ip: "10.0.0.1\u0000") do
          PermissionForge.with_audit_actor(label: "ops\u0000@acme\r\n#{long}", reason: "REASON=a\u0000b\n#{long}") do
            Audit.record('report.generated', subject_user_id: "u\u00001#{long}", record_label: "lab\u0000el#{long}",
                                             record_type: "T\nX", record_id: long, record_uuid: long, permission_set_uuid: long)
          end
        end

        event = assert_audit_event('report.generated', record_type: 'T X')
        %i[actor_label reason subject_user_id record_label record_id record_uuid permission_set_uuid request_id ip].each do |column|
          value = event.public_send(column)
          assert_operator value.length, :<=, 255, column
          assert_no_match(/[\u0000-\u001F\u007F-\u009F]/, value, column)
        end
        assert event.actor_label.start_with?('ops@acme  LLL')
        assert event.reason.start_with?('REASON=ab LLL')
        assert_equal '10.0.0.1', event.ip
      end

      test 'the notification payload carries the cleaned values too' do
        received = nil
        subscriber = ActiveSupport::Notifications.subscribe('report.generated.permission_forge') { |e| received = e.payload }
        Audit.record('report.generated', reason: "a\u0000b")

        assert_equal 'ab', received[:reason]
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
    end
  end
end
