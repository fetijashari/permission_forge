# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # Every enforcement path on the host model shapes the other dummy models
  # do not have: a namespaced model on a uuid primary key (Billing::Invoice)
  # and one with an encrypted column and an enum (PfEncryptedNote). One test
  # per SHAPE × PATH, so a path that assumes an integer `id`, a top-level
  # constant or a plain column fails by name. A new shape is one SHAPES
  # entry (a dummy model whose rows never touch User or Account); a new
  # path one PATHS entry.
  class HostShapesTest < ActionDispatch::IntegrationTest
    # Per model: the field masked (and how), the field hidden, the field
    # editable, and the attributes of the current user's row and of
    # somebody else's. Every shape has an owner_id column (the row rule).
    SHAPES = {
      'Billing::Invoice' => {
        masked: 'customer_email', strategy: 'email', hidden: 'amount_cents', editable: 'number',
        own: { 'number' => 'INV-1', 'amount_cents' => 1250, 'customer_email' => 'pay@acme.test' },
        other: { 'number' => 'INV-2', 'amount_cents' => 999, 'customer_email' => 'other@acme.test' }
      },
      'PfEncryptedNote' => {
        masked: 'body', strategy: 'full', hidden: 'status', editable: 'title',
        own: { 'title' => 'Mine', 'body' => 'the secret text', 'status' => 'published' },
        other: { 'title' => 'Theirs', 'body' => 'their text', 'status' => 'draft' }
      }
    }.freeze

    PATHS = {
      'permission_scoped lists the rows the rule allows and no other' => lambda { |_shape|
        assert_equal [@own.id], @model.permission_scoped.map(&:id)
        assert_equal [@own.id], @model.permission_scoped.pluck(@model.primary_key)
      },

      'find_by! finds an allowed row, refuses a denied one and misses a missing one' => lambda { |_shape|
        key = @model.primary_key
        assert_equal @own, @model.find_by!(key => @own.id)
        assert_raises(Concerns::PermissionScopedFindable::NotAuthorizedError) { @model.find_by!(key => @other.id) }
        assert_raises(ActiveRecord::RecordNotFound) { @model.find_by!(key => 'no-such-row') }
        assert_raises(Concerns::PermissionScopedFindable::NotAuthorizedError) { @model.find_by(key => @other.id) }
        assert_nil @model.find_by(key => 'no-such-row')
      },

      'the getters mask the masked field, hide the hidden one and leave the key and the rest' => lambda { |shape|
        record = @model.find(@own.id)
        assert_equal masked_value(shape), record.public_send(shape[:masked])
        assert_hidden record.public_send(shape[:hidden])
        assert_equal shape[:own][shape[:editable]], record.public_send(shape[:editable])
        assert_equal @own.id, record.id
        assert_equal shape[:own][shape[:masked]], record.read_attribute_before_type_cast(shape[:masked]).to_s unless shape[:masked] == 'body'
      },

      'as_json leaves the hidden key out, masks the masked one and keeps the key' => lambda { |shape|
        json = @model.find(@own.id).as_json
        assert_not json.key?(shape[:hidden]), json.keys.inspect
        assert_equal masked_value(shape), json[shape[:masked]]
        assert_equal @own.id, json[@model.primary_key]
        assert_equal shape[:own][shape[:editable]], json[shape[:editable]]
      },

      'PermitsAttributes keeps the editable key only' => lambda { |shape|
        params = { shape[:editable] => 'new', shape[:masked] => 'x', shape[:hidden] => 'y', 'owner_id' => 1 }
        assert_equal({ shape[:editable] => 'new' }, Services::PermitsAttributes.call(resource: @own, permitted_params: params))
        assert_equal({ shape[:editable] => 'new' }, Services::PermitsAttributes.call(resource: @model, permitted_params: params))
      },

      'FiltersResponseAttributes removes the hidden key and masks the masked one' => lambda { |shape|
        attributes = { shape[:editable] => 'v', shape[:masked] => shape[:own][shape[:masked]], shape[:hidden] => 'h' }
        filtered = Services::FiltersResponseAttributes.call(attributes: attributes, resource_name: @model.name, user: @user)
        assert_equal 'v', filtered[shape[:editable]]
        assert_equal masked_value(shape), filtered[shape[:masked]]
        assert_not filtered.key?(shape[:hidden]), filtered.inspect
      },

      "the user's resource checks answer under the model's name" => lambda { |_shape|
        assert @user.can_read?(@model.name)
        assert @user.can_edit?(@model.name)
        assert_not @user.can_delete?(@model.name)
        assert_equal [@set.uuid], @user.permissions_hash_for(@model.name)[:source_permission_sets].map { |set| set[:uuid] }
      },

      'the admin offers the model, shows its Resource page and opens its field drawers' => lambda { |shape|
        get "/permission_forge/permission_sets/#{@set.id}/resources/new"
        assert_response :ok
        assert_select "option[value='#{@model.name}'], input[value='#{@model.name}']", minimum: 1

        get "/permission_forge/permission_sets/#{@set.id}/resources/#{@model.name}"
        assert_response :ok
        fields = shape.values_at(:masked, :hidden, :editable)
        fields.each { |field| assert_select '.pf-fields__label', text: field.humanize }
        fields.each do |field|
          get "/permission_forge/permission_sets/#{@set.id}/resources/#{@model.name}/fields/#{field}"
          assert_response :ok
        end
      },

      'the API generates field rows for the columns nobody configured' => lambda { |shape|
        post "/permission_forge/api/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}/generate_fields",
             params: { grant_all: true }
        assert_response :created
        names = JSON.parse(response.body)['data'].map { |row| row['name'] }
        ignored = PermissionForge.configuration.ignored_fields.map(&:to_s)
        assert_includes names, 'created_at'
        assert_equal (@model.column_names - ignored - %w[owner_id] - shape.values_at(:masked, :hidden, :editable)).sort, names.sort
      }
    }.freeze

    setup do
      @old_forgery = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = false
    end

    teardown do
      ActionController::Base.allow_forgery_protection = @old_forgery
    end

    SHAPES.each do |name, shape|
      PATHS.each do |path, check|
        test "#{name}: #{path}" do
          prepare(name, shape)
          instance_exec(shape, &check)
        end
      end
    end

    private

    # A Permission Set for the model: read, create and edit on the resource,
    # the three configured fields, owner_id readable, a row rule on owner_id,
    # the current user assigned; the concern applied as a Resource row
    # applies it; one row of the user's and one of somebody else's.
    def prepare(name, shape)
      @model = name.constantize
      @user = create_user(name: 'Owner')
      other_user = create_user(name: 'Other')
      @set = create_permission_set(name: "#{name} readers")
      @resource = create_resource(permission_set: @set, name: name, read_access: true, create_access: true, edit_access: true)
      create_fields(shape)
      create_permission_set_rule(permission_set: @set, resource: @resource, field_name: 'owner_id', field_value: 'current_user',
                                 operator: 'equal', include_nulls: false)
      create_permission_set_user(user: @user, permission_set: @set)
      PermissionForge::MaskedModels.apply(only: name)
      assert Concerns::MaskedAttributes.applied?(@model), "#{name} did not get MaskedAttributes"
      @own = @model.create!(shape[:own].merge('owner_id' => @user.id))
      @other = @model.create!(shape[:other].merge('owner_id' => other_user.id))
      Current.user = @user
    end

    def create_fields(shape)
      create_resource_field(resource: @resource, name: shape[:masked], label: shape[:masked].humanize, read_access: true,
                                                 mask_access: true, mask_strategy: shape[:strategy])
      create_resource_field(resource: @resource, name: shape[:hidden], label: shape[:hidden].humanize, read_access: false)
      create_resource_field(resource: @resource, name: shape[:editable], label: shape[:editable].humanize, read_access: true,
                                                 edit_access: true)
      create_resource_field(resource: @resource, name: 'owner_id', label: 'Owner', read_access: true)
    end

    def masked_value(shape)
      Services::MaskValue.call(shape[:own][shape[:masked]], strategy: shape[:strategy])
    end

    # config.hidden_attribute_value (nil in the suite).
    def assert_hidden(value)
      hidden = PermissionForge.configuration.hidden_attribute_value
      hidden.nil? ? assert_nil(value) : assert_equal(hidden, value)
    end
  end
end
