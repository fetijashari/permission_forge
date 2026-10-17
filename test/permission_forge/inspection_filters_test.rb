# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # Field test: with filter_parameters_integration on, the console printed
  # PermissionSet / Resource / ResourceField `name: [FILTERED]` — the GDPR
  # pattern `\Aname\z` (meant for people's names) hid the gem's own
  # configuration names.
  class InspectionFiltersTest < ActiveSupport::TestCase
    # What a Rails 8 app filters, plus the gem's GDPR patterns.
    APP_FILTERS = %i[passw email secret token _key crypt salt certificate otp ssn cvv cvc].freeze
    MODELS = [PermissionSet, PermissionSetGroup, Resource, ResourceField, ResourceAction, PermissionSetRule].freeze

    def filters = APP_FILTERS + Configuration.new.gdpr_field_patterns.keys

    def filtered(list, attributes)
      ActiveSupport::ParameterFilter.new(list).filter(attributes.index_with { 'v' }).select { |_, v| v == '[FILTERED]' }.keys
    end

    test 'the configuration names are spared; everything else the filters matched stays hidden' do
      spared = InspectionFilters.sparing(filters, InspectionFilters::CONFIGURATION_NAMES)
      attributes = %w[name label field_name email first_name contact_name phone home_address ip user_token field_value
                      description NAME Label]

      assert_includes filtered(filters, attributes), 'name', 'the GDPR patterns hide a bare name'
      assert_equal filtered(filters, attributes) - %w[name NAME label Label], filtered(spared, attributes)
      assert_equal %w[email first_name contact_name phone home_address ip user_token].sort,
                   (filtered(spared, attributes) & %w[email first_name contact_name phone home_address ip user_token]).sort
    end

    test 'a String or Symbol filter keeps its Rails reading: anywhere in the name, ignoring case' do
      spared = InspectionFilters.sparing([:name, 'Label', 'a.b'], %w[name label])

      assert_equal %w[full_name LABEL_TEXT], filtered(spared, %w[name label full_name LABEL_TEXT other])
      assert_equal ['a.b'], filtered(spared, %w[a.b])
    end

    test 'a Regexp keeps its options and anchors, also under /x with a trailing comment' do
      spared = InspectionFilters.sparing([/\Afirst # people
                                         /x, /secret/i, /\Aname\z|_name\z/], %w[name])

      assert_equal %w[first firstname_x SECRET_key last_name],
                   filtered(spared, %w[first firstname_x xfirst SECRET_key name last_name nickname])
    end

    test 'a Proc filter is kept as it is' do
      proc_filter = ->(_key, value) { value.replace('gone') if value.is_a?(String) }

      assert_same proc_filter, InspectionFilters.sparing([proc_filter], %w[name]).first
    end

    test 'only Regexps (and Procs) are set: Rails 8 copies Strings and Symbols back into filter_parameters' do
      assert(InspectionFilters.sparing(filters, %w[name]).all?(Regexp))
    end

    test "a gem model's inspect shows its name under the GDPR patterns; another attribute stays filtered" do
      with_gdpr_parent do |parent|
        rule = Class.new(parent) { def self.name = 'PfInspectRule' }
        rule.table_name = PermissionSetRule.table_name
        InspectionFilters.show_configuration_names(rule)

        shown = rule.new(name: 'Own customers', field_name: 'email', field_value: 'v@example.test').inspect
        assert_match(/name: "Own customers"/, shown)
        assert_match(/field_name: "email"/, shown)
        host = Class.new(parent) { def self.name = 'PfInspectHost' }
        host.table_name = 'customers'
        assert_includes host.new(name: 'Jane Doe').inspect, 'name: [FILTERED]', 'a host model still filters'
      end
    end

    test 'the gem models set their own filters from the inherited ones' do
      MODELS.each do |model|
        expected = InspectionFilters.sparing(model.superclass.filter_attributes, InspectionFilters::CONFIGURATION_NAMES)
        assert_equal expected.map(&:to_s), model.filter_attributes.map(&:to_s), model.name
      end
    end

    test "AuditEvent hides the labels that name people when the application's filters hide a name" do
      with_gdpr_parent do |parent|
        event = Class.new(parent) { def self.name = 'PfInspectEvent' }
        event.table_name = AuditEvent.table_name
        InspectionFilters.hide_people_labels(event)

        shown = event.new(actor_label: 'Ana Krasniqi', record_label: 'Bo Berisha', event: 'assignment.granted').inspect
        assert_match(/actor_label: \[FILTERED\], .*record_label: \[FILTERED\]/, shown)
        assert_match(/event: "assignment.granted"/, shown)
      end
    end

    # Rails 8 copies a model's String / Symbol entries into
    # config.filter_parameters: AuditEvent sets Regexps only, also for the
    # host's own :passw-style entries it inherits.
    test 'AuditEvent sets only Regexps, its inherited Strings and Symbols included' do
      parent = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      parent.filter_attributes = [:passw, 'secret', :name]
      event = Class.new(parent) { def self.name = 'PfInspectEventSymbols' }
      event.table_name = AuditEvent.table_name
      InspectionFilters.hide_people_labels(event)

      assert(event.filter_attributes.all?(Regexp), event.filter_attributes.inspect)
      shown = event.new(actor_label: 'Ana Krasniqi', reason: 'secret-ish').inspect
      assert_match(/actor_label: \[FILTERED\]/, shown)
    end

    test 'AuditEvent keeps the inherited filters when nothing hides a name' do
      parent = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      parent.filter_attributes = %i[passw]
      event = Class.new(parent) { def self.name = 'PfInspectEventPlain' }
      InspectionFilters.hide_people_labels(event)

      assert_equal %i[passw], event.filter_attributes
    end

    private

    # An abstract parent filtering like an app with filter_parameters_integration,
    # so ActiveRecord::Base stays as the suite configured it.
    def with_gdpr_parent
      parent = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      parent.filter_attributes = filters
      yield parent
    end
  end
end
