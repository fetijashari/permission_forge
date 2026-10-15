module PermissionForge
  module Api
    module ResponseRenderer
      extend ActiveSupport::Concern

      private

      def render_record(record, serializer_class)
        if ams_serializer?(serializer_class)
          render json: record, serializer: serializer_class, root: :data, status: :ok
        else
          render json: { data: serializer_class.new(record).as_json }, status: :ok
        end
      end

      def render_created(record, serializer_class)
        if ams_serializer?(serializer_class)
          render json: record, serializer: serializer_class, root: :data, status: :created
        else
          render json: { data: serializer_class.new(record).as_json }, status: :created
        end
      end

      def render_collection(scope, serializer_class)
        paginator = PermissionForge.configuration.api_pagination_handler
        records = paginator ? paginate_scope(scope, paginator) : default_paginate_scope(scope)
        meta = pagination_meta(records)

        if ams_serializer?(serializer_class)
          render json: records, each_serializer: serializer_class, root: :data, meta: meta, status: :ok
        else
          data = serializer_class.collection(records)
          render json: { data: data, meta: meta }, status: :ok
        end
      end

      def render_validation_errors(record)
        render_unprocessable(record.errors.messages)
      end

      # The one 422 shape: `messages` maps a field (a parameter, an attribute,
      # or "base" when the error names none) to its messages, for validation
      # errors and unreadable input alike.
      def render_unprocessable(messages)
        render json: { error: { status: 422, messages: messages } }, status: :unprocessable_entity
      end

      # An input error (ParamShapes::InvalidParam, a missing or malformed
      # body section, Rails' own BadRequest) as field-keyed messages.
      def render_input_error(error)
        render_unprocessable(input_error_messages(error))
      end

      def input_error_messages(error)
        case error
        when PermissionForge::ParamShapes::InvalidParam then { error.param => [error.detail] }
        when ActionController::ParameterMissing
          { error.param.to_s => [I18n.t('permission_forge.api.errors.section_missing')] }
        else { 'base' => [error.message] }
        end
      end

      # Saves a record and renders the created resource or its validation errors.
      def save_and_render(record, serializer_type)
        if record.save
          render_created(record, serializer_for(serializer_type))
        else
          render_validation_errors(record)
        end
      end

      def render_not_authorized(message = nil)
        msg = message || I18n.t('permission_forge.api.errors.forbidden')
        render json: { error: { status: 403, messages: msg } }, status: :forbidden
      end

      def render_not_found(message = nil)
        msg = message || I18n.t('permission_forge.api.errors.not_found')
        render json: { error: { status: 404, messages: msg } }, status: :not_found
      end

      def ams_serializer?(serializer_class)
        defined?(ActiveModel::Serializer) && serializer_class < ActiveModel::Serializer
      end
    end
  end
end
