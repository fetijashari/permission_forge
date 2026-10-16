# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Services
    # Review R1 #7: a copy of a set holding a row today's validations refuse
    # — a rule operator or join type this version does not know, a mask
    # strategy that is not one, an IP list with an entry that is no address
    # — raised ActiveRecord::RecordInvalid (a 500 in the admin's Duplicate).
    # A copy keeps its original's stored values, as it already did for a
    # rule's value: the copy behaves exactly like the original (the rule
    # matches nothing, the field masks fully, the condition never passes).
    # Every copy path is tried with every poisoned row.
    class CopyStoredValuesTest < ActionDispatch::IntegrationTest
      HEADERS = { 'CONTENT_TYPE' => 'application/json' }.freeze

      # name => [how the row is poisoned, what the copy must hold]
      POISONS = {
        rule_operator: ->(t) { t.rule.update_columns(operator: 'regex') },
        rule_join_type: ->(t) { t.rule.update_columns(join_type: 'inner', field_accessor_path: 'supplier') },
        mask_strategy: ->(t) { t.field.update_columns(mask_strategy: 'emial') },
        allowed_ips: ->(t) { t.set.update_columns(allowed_ips: '10.0.0.0/8 office') }
      }.freeze

      # path => the copy it makes, or nil (a 500 or a refusal fails the test)
      PATHS = {
        cloner: ->(t) { PermissionSetCloner.call(permission_set: t.set, attrs: { name: 'Service copy' }) },
        admin_duplicate: lambda { |t|
          t.post "/permission_forge/permission_sets/#{t.set.id}/duplicate"
          t.assert_response :redirect
          PermissionForge::PermissionSet.find_by(name: 'Poisoned (copy)')
        },
        admin_start_from: lambda { |t|
          t.post '/permission_forge/permission_sets', params: { type: 'granting', name: 'Started', start_from_granting: t.set.id }
          t.assert_response :redirect
          PermissionForge::PermissionSet.find_by(name: 'Started')
        },
        admin_group_duplicate: lambda { |t|
          t.post "/permission_forge/groups/#{t.group.id}/duplicate"
          t.assert_response :redirect
          PermissionForge::PermissionSetGroup.where.not(id: t.group.id).last&.permission_sets&.first
        },
        api_clone: lambda { |t|
          t.post "/permission_forge/api/permission_sets/#{t.set.uuid}/clone", params: { name: 'API copy' }.to_json, headers: HEADERS
          t.assert_response :created
          PermissionForge::PermissionSet.find_by(name: 'API copy')
        },
        api_group_clone: lambda { |t|
          t.post "/permission_forge/api/permission_set_groups/#{t.group.uuid}/clone", params: { name: 'API group' }.to_json,
                                                                                     headers: HEADERS
          t.assert_response :created
          PermissionForge::PermissionSetGroup.find_by(name: 'API group')&.permission_sets&.first
        }
      }.freeze

      attr_reader :set, :rule, :field, :group

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @group = create_permission_set_group(name: 'Team')
        @set = create_permission_set(name: 'Poisoned', permission_set_group: @group)
        resource = create_resource(permission_set: @set, read_access: true)
        @field = create_resource_field(resource: resource, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        @rule = create_permission_set_rule(permission_set: @set, resource: resource, field_name: 'name', field_value: 'x')
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      POISONS.each do |poison, apply|
        PATHS.each do |path, copy_of|
          test "#{path} copies a set holding a stored #{poison} and keeps it" do
            apply.call(self)
            copy = copy_of.call(self)

            assert copy, "#{path}: a copy is made"
            assert_kept(poison, copy)
          end
        end
      end

      # A row still refused on copy (here: Modify All without View All) is a
      # flash naming what failed, never a 500.
      test 'a copy the validations still refuse is a flash naming the row, in the admin' do
        @rule.resource.update_columns(view_all: false, modify_all: true)

        post "/permission_forge/permission_sets/#{@set.id}/duplicate"

        assert_redirected_to "/permission_forge/permission_sets/#{@set.id}"
        assert_match(/Customer/, flash[:alert])
        assert_match(/view_all|View All/i, flash[:alert])
        assert_nil PermissionForge::PermissionSet.find_by(name: 'Poisoned (copy)'), 'nothing half-made'

        post "/permission_forge/groups/#{@group.id}/duplicate"

        assert_redirected_to "/permission_forge/groups/#{@group.id}"
        assert_match(/Customer/, flash[:alert])

        post '/permission_forge/permission_sets', params: { type: 'granting', name: 'Started', start_from_granting: @set.id }

        assert_response :unprocessable_entity
        assert_match(/Customer/, response.body)
      end

      private

      def assert_kept(poison, copy)
        copied_resource = copy.resources.first
        case poison
        when :rule_operator, :rule_join_type
          copied = copied_resource.permission_set_rules.first
          original = @rule.reload

          assert_equal original.attributes.slice('operator', 'join_type', 'field_accessor_path'),
                       copied.attributes.slice('operator', 'join_type', 'field_accessor_path')
          assert_equal Operators::RuleProblem.for(original).kind, Operators::RuleProblem.for(copied)&.kind, 'matches nothing, as the original'
        when :mask_strategy
          assert_equal 'emial', copied_resource.resource_fields.find_by(name: 'email').mask_strategy
          assert_equal '****', MaskValue.call('a@b.c', strategy: 'emial')[0, 4], 'masks fully, as the original'
        when :allowed_ips
          assert_equal '10.0.0.0/8 office', copy.allowed_ips
          assert_predicate copy, :conditions_broken?
        end
      end
    end
  end
end
