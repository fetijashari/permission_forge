module PermissionForge
  # Person labels, avatars and assignment expiry/review cells.
  #
  # @api private
  module PeopleHelper
    def pf_person(user)
      @pf_person_labels ||= {}
      @pf_person_labels[[user.class.name, user.id]] ||= PermissionForge::Admin::PersonLabel.new(user)
    end

    def pf_person_name(user)
      user ? pf_person(user).name : pf_ui('audit.system')
    end

    def pf_avatar(user, size: nil)
      classes = ['pf-avatar', ("pf-avatar--#{size}" if size)].compact.join(' ')
      content_tag(:span, pf_person(user).initials, class: classes, 'aria-hidden': true)
    end

    # Avatar + name + email block.
    def pf_person_cell(user, href: nil)
      label = pf_person(user)
      body = safe_join([pf_avatar(user),
                        content_tag(:span, class: 'pf-stack pf-stack--tight pf-ellipsis') do
                          safe_join([content_tag(:span, label.name, class: 'pf-person-name pf-ellipsis'),
                                     (content_tag(:span, label.secondary, class: 'pf-person-email pf-ellipsis') if label.secondary)].compact)
                        end])
      href ? link_to(body, href, class: 'pf-cell-person') : content_tag(:span, body, class: 'pf-cell-person')
    end

    # --- assignments --------------------------------------------------------

    # [text, css tone class] for an assignment end date. "Ended" and "ends
    # in" are PermissionSetUser's (.ended?, ENDING_SOON_DAYS — the window of
    # Home's "ending soon" card and the People page filter).
    def pf_expiry(expires_at)
      days = PermissionForge::Admin::ExpiryPresets.days_left(expires_at)
      assignments = PermissionForge::PermissionSetUser
      return [pf_ui('expiry.none'), 'pf-text-2'] if days.nil?
      return [pf_ui('expiry.expired', date: pf_date(expires_at, year: false)), 'pf-text-3'] if assignments.ended?(expires_at)
      return [pf_ui('expiry.today'), 'pf-text-warn'] if days.zero?
      return [pf_ui('expiry.ends_in', count: days, date: pf_date(expires_at, year: false)), 'pf-text-warn'] if days <= assignments::ENDING_SOON_DAYS

      [pf_ui('expiry.until', date: pf_date(expires_at, year: false)), 'pf-text-2']
    end

    def pf_expiry_tag(expires_at)
      text, tone = pf_expiry(expires_at)
      content_tag(:span, text, class: tone)
    end

    # "✓ Reviewed by Ana on 3 Oct 2026" / "– Never reviewed"; a warning
    # (⚠, warn tone) when the assignment is due for review (pf_stale?).
    def pf_reviewed(assignment)
      stale = pf_stale?(assignment)
      reviewed = pf_review_known?(assignment) && assignment.reviewed_at.present?
      glyph = content_tag(:span, pf_review_glyph(stale, reviewed), 'aria-hidden': true)
      content_tag(:span, safe_join([glyph, pf_review_text(assignment)], ' '), class: "pf-fs-12 #{stale ? 'pf-text-warn' : 'pf-text-3'}")
    end

    def pf_review_glyph(stale, reviewed)
      return '⚠' if stale

      reviewed ? '✓' : '–'
    end

    # "Reviewed by <person> on <date>", "Reviewed on <date>" (no person
    # recorded, e.g. a password-prompt login), or "Never reviewed". Without
    # the review columns (upgrade not run) the last update counts, as before.
    def pf_review_text(assignment)
      return pf_ui('assignment.reviewed', when: pf_relative(assignment.last_reviewed_at)) unless pf_review_known?(assignment)

      reviewed_at = assignment.reviewed_at
      return pf_ui('assignment.never_reviewed') if reviewed_at.nil?

      reviewer = pf_reviewer(assignment)
      return pf_ui('assignment.reviewed_on', date: pf_date(reviewed_at)) unless reviewer

      pf_ui('assignment.reviewed_by', who: pf_person_name(reviewer), date: pf_date(reviewed_at))
    end

    def pf_review_known?(assignment)
      assignment.class.respond_to?(:review_supported?) && assignment.class.review_supported?
    end

    # The person who last reviewed the assignment (memoized per page), or nil.
    def pf_reviewer(assignment)
      id = assignment.try(:reviewed_by_id)
      return nil if id.blank?

      @pf_reviewers ||= {}
      return @pf_reviewers[id.to_s] if @pf_reviewers.key?(id.to_s)

      @pf_reviewers[id.to_s] = PermissionForge.configuration.user_model.find_by(id: id)
    end

    # Due for review: PermissionSetUser#stale? at the admin's threshold
    # (Admin::AttentionItems.stale_days — Home's Stale card and the audit's
    # stale_assignments use the same one, also while the setting is nil).
    def pf_stale?(assignment)
      assignment.stale?(PermissionForge::Admin::AttentionItems.stale_days)
    end

    # Calendar date (not time) for each expiry preset, for labels.
    def pf_expiry_preset_date(key)
      date = PermissionForge::Admin::ExpiryPresets.date_for(key)
      date ? pf_date(date) : nil
    end
  end
end
