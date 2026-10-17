module PermissionForge
  # One plain-language line per ChangeSet change (the "Review and save" list).
  #
  # @api private
  module ChangesHelper
    # ChangeSet::Change#kind => the helper that words it. A new kind is one
    # entry here plus its helper.
    CHANGE_DESCRIBERS = {
      set_attr: :pf_set_attr_change, resource_flag: :pf_resource_flag_change, resource_text: :pf_resource_text_change,
      field_level: :pf_field_level_change, new_field: :pf_field_level_change, field_attr: :pf_field_attr_change,
      action: :pf_action_change, new_action: :pf_new_action_change
    }.freeze

    def pf_change_description(change)
      describer = CHANGE_DESCRIBERS[change.kind]
      send(describer, change) if describer
    end

    def pf_resource_text_change(change)
      pf_ui('changes.resource_text', resource: pf_resource_label(change.record),
                                     attribute: pf_ui("changes.attributes.#{change.attribute}"))
    end

    def pf_action_change(change)
      muting = change.resource&.permission_set&.is_muting
      key = if muting then change.to ? 'changes.action_muted' : 'changes.action_unmuted'
            else change.to ? 'changes.action_on' : 'changes.action_off'
            end
      pf_ui(key, resource: pf_resource_label(change.resource), action: change.record.display_name)
    end

    # A discovered controller action added to the set, followed by what that
    # means for everyone: "Customer: Export added, permitted (this makes it
    # managed: ...)".
    def pf_new_action_change(change)
      resource = change.resource
      action = change.record
      key = if resource.permission_set.is_muting then change.to ? 'changes.action_new_muted' : 'changes.action_new_unmuted'
            else change.to ? 'changes.action_new_on' : 'changes.action_new_off'
            end
      text = pf_ui(key, resource: pf_resource_label(resource), action: action.display_name)
      "#{text} #{pf_action_managed_note(resource, action.name)}"
    end

    # The first row for an action makes it managed for everyone (under :allow
    # that restricts it; under :block, the default, it opens it to the people
    # permitted); later rows join the sets that already manage it.
    def pf_action_managed_note(resource, key)
      return pf_ui('changes.action_managed_later') unless resource.in_effect?

      across = pf_action_across(resource.name)
      return pf_action_managed_first unless across.managed?(key)

      sets = across.permitting_sets(key).map(&:name)
      sets.any? ? pf_ui('changes.action_managed_already', sets: sets.join(', ')) : pf_ui('changes.action_managed_nobody')
    end

    def pf_action_managed_first
      if PermissionForge.configuration.allow_unconfigured_actions?
        pf_ui('changes.action_managed_first_allowed')
      else
        pf_ui('changes.action_managed_first_blocked')
      end
    end

    # One lookup per resource name per page.
    def pf_action_across(resource_name)
      (@pf_action_across ||= {})[resource_name] ||= PermissionForge::Admin::ActionAcrossSets.new(resource_name)
    end

    def pf_set_attr_change(change)
      case change.attribute
      when 'is_active' then pf_ui(change.to ? 'changes.set_on' : 'changes.set_off')
      when 'permission_set_group_id'
        group = change.to && PermissionForge::PermissionSetGroup.find_by(id: change.to)
        group ? pf_ui('changes.set_group', group: pf_record_name(group)) : pf_ui('changes.set_no_group')
      else pf_ui('changes.set_text', attribute: pf_ui("changes.attributes.#{change.attribute}"))
      end
    end

    def pf_resource_flag_change(change)
      key = change.to ? 'changes.flag_on' : 'changes.flag_off'
      key = "#{key}_muting" if change.resource&.permission_set&.is_muting
      text = pf_ui(key, resource: pf_resource_label(change.resource), flag: pf_flag_name(change.attribute))
      change.cascaded ? "#{text} #{pf_ui('changes.cascaded')}" : text
    end

    # A flag the request turned on that stays off (ChangeSet#refused):
    # "Customer: Edit not turned on, because Read is off".
    def pf_refusal_description(refusal)
      pf_ui("changes.not_applied_#{refusal.needs}", resource: pf_resource_label(refusal.resource),
                                                    flag: pf_flag_name(refusal.attribute))
    end

    def pf_flag_name(flag)
      pf_ui("flags_short.#{flag}")
    end

    def pf_field_level_change(change)
      from_level, = Array(change.from)
      args = { resource: pf_resource_label(change.resource), field: pf_change_field_name(change.record),
               to: pf_change_level_text(change.to) }
      text = if from_level
               pf_ui('changes.field_level', **args, from: pf_level_label(from_level))
             else
               pf_ui('changes.field_new', **args)
             end
      change.cascaded ? "#{text} #{pf_ui('changes.cascaded_field')}" : text
    end

    # "Masked (email)" for [level, strategy].
    def pf_change_level_text(level_and_strategy)
      level, strategy = Array(level_and_strategy)
      text = pf_level_label(level)
      %w[masked mask].include?(level) && strategy ? "#{text} (#{pf_mask_strategy_label(strategy)})" : text
    end

    # A field row named as everywhere else (Admin::FieldLabel: a label the
    # gem generated is no label).
    def pf_change_field_name(field)
      pf_field_label_text(field.resource&.name, field.name, row: field)
    end

    def pf_field_attr_change(change)
      field = change.record
      if change.attribute == 'is_active'
        return pf_ui(change.to ? 'changes.field_on' : 'changes.field_off', resource: pf_resource_label(change.resource),
                                                                           field: pf_change_field_name(field))
      end

      pf_ui('changes.field_text', resource: pf_resource_label(change.resource), field: field.name,
                                  attribute: pf_ui("changes.attributes.#{change.attribute}"))
    end
  end
end
