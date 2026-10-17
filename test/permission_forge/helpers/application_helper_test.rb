# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  class ApplicationHelperTest < ActionView::TestCase
    tests PermissionForge::ApplicationHelper

    # Plain objects exposing different attribute subsets — the dummy User model
    # only has some of the columns the label chain probes for.
    NamedUser = Struct.new(:id, :name)
    NamedEmailUser = Struct.new(:id, :name, :email)
    EmailOnlyUser = Struct.new(:id, :email)
    EmailAddressUser = Struct.new(:id, :name, :email_address) # Rails 8's authentication generator
    FallbackNameUser = Struct.new(:id, :name, :full_name, :display_name)
    ComposedNameUser = Struct.new(:id, :first_name, :last_name)
    BareUser = Struct.new(:id)

    # AR subclass whose reader hides the column value (mimics MaskedAttributes) —
    # the helper must fall back to read_attribute_before_type_cast.
    MaskedNameUser = Class.new(User) do
      def name
        nil
      end
    end

    # AR subclass whose reader returns a masked sentinel (MaskedAttributes with
    # mask_access) — the raw column value must win over the reader.
    MaskedValueUser = Class.new(User) do
      def name
        'Te** Us**'
      end
    end

    # AR subclass composing a virtual value over a blank column — the helper
    # must fall back to the reader when the raw column is blank.
    ComposingReaderUser = Class.new(User) do
      def name
        'Composed Reader'
      end
    end

    teardown do
      PermissionForge.configuration.user_label_formatter = nil
    end

    # ---------- pf_status_badge ----------

    test 'pf_status_badge renders a muted badge with a glyph when inactive' do
      html = pf_status_badge(false)

      assert_includes html, 'pf-badge--off'
      assert_includes html, '○'
      assert_includes html, I18n.t('permission_forge.shared.inactive')
    end

    test 'pf_status_badge renders a granted badge with a glyph when active' do
      html = pf_status_badge(true)

      assert_includes html, 'pf-badge--grant'
      assert_includes html, '●'
      assert_includes html, I18n.t('permission_forge.shared.active')
    end

    # ---------- pf_operator_label ----------

    test 'pf_operator_label translates known operators' do
      assert_equal I18n.t('permission_forge.ui.operators.equal'), pf_operator_label('equal')
    end

    test 'pf_operator_label shows an unknown operator as stored, never humanized' do
      assert_equal 'made_up_operator', pf_operator_label('made_up_operator')
    end

    # ---------- pf_user_option_label ----------

    test 'pf_user_option_label honors a configured user_label_formatter' do
      PermissionForge.configuration.user_label_formatter = ->(u) { "Custom #{u.name}" }

      assert_equal 'Custom Alice #7', pf_user_option_label(NamedUser.new(7, 'Alice'))
    end

    test 'pf_user_option_label falls through to the name when the formatter returns blank (Admin::PersonLabel)' do
      PermissionForge.configuration.user_label_formatter = ->(_u) { '   ' }

      assert_equal 'Alice #7', pf_user_option_label(NamedUser.new(7, 'Alice'))
    end

    test 'pf_time_ago is deprecated and reads as pf_relative' do
      PermissionForge::Deprecation.reset!
      warnings = []
      previous = PermissionForge.deprecator.behavior
      PermissionForge.deprecator.behavior = ->(message, *) { warnings << message }
      assert_equal pf_relative(2.days.ago), pf_time_ago(2.days.ago)
      assert_equal pf_relative(nil), pf_time_ago(nil)
      assert_equal 1, warnings.grep(/pf_time_ago is deprecated; use pf_relative/).size, 'warned once'
    ensure
      PermissionForge.deprecator.behavior = previous
      PermissionForge::Deprecation.reset!
    end

    test 'pf_user_option_label combines name and email' do
      user = NamedEmailUser.new(3, 'Alice', 'alice@example.com')

      assert_equal 'Alice (alice@example.com) #3', pf_user_option_label(user)
    end

    test 'pf_user_option_label uses the name alone when no email exists' do
      assert_equal 'Alice #4', pf_user_option_label(NamedUser.new(4, 'Alice'))
    end

    test 'pf_user_option_label uses the email alone when no name variant exists' do
      user = EmailOnlyUser.new(5, 'bob@example.com')

      assert_equal 'bob@example.com #5', pf_user_option_label(user)
    end

    test 'pf_user_option_label reads email_address when there is no email' do
      assert_equal 'bob@example.com #5', pf_user_option_label(EmailAddressUser.new(5, nil, 'bob@example.com'))
      assert_equal 'Bob (bob@example.com) #6', pf_user_option_label(EmailAddressUser.new(6, 'Bob', 'bob@example.com'))
    end

    test 'pf_user_option_label falls through blank name to full_name' do
      user = FallbackNameUser.new(6, '  ', 'Full Name', nil)

      assert_equal 'Full Name #6', pf_user_option_label(user)
    end

    test 'pf_user_option_label falls through blank name variants to display_name' do
      user = FallbackNameUser.new(7, nil, '   ', 'Display Name')

      assert_equal 'Display Name #7', pf_user_option_label(user)
    end

    test 'pf_user_option_label composes first_name and last_name' do
      user = ComposedNameUser.new(8, 'Jane', 'Doe')

      assert_equal 'Jane Doe #8', pf_user_option_label(user)
    end

    test 'pf_user_option_label composes a partial name when only one part is present' do
      user = ComposedNameUser.new(9, ' Jane ', nil)

      assert_equal 'Jane #9', pf_user_option_label(user)
    end

    test 'pf_user_option_label falls back to the translated User label' do
      expected = "#{I18n.t('permission_forge.shared.user')} #10"

      assert_equal expected, pf_user_option_label(BareUser.new(10))
    end

    # ---------- pf_raw_user_attribute ----------

    test 'pf_user_option_label reads raw column values when a reader is overridden to blank' do
      user = create_user(name: 'Raw Name', email: 'raw@example.com')
      masked = MaskedNameUser.find(user.id)

      assert_nil masked.name
      assert_equal "Raw Name (raw@example.com) ##{user.id}", pf_user_option_label(masked)
    end

    test 'pf_raw_user_attribute prefers the raw column over a masked reader value' do
      user = create_user(name: 'Real Name', email: 'real@example.com')
      masked = MaskedValueUser.find(user.id)

      assert_equal 'Te** Us**', masked.name
      assert_equal "Real Name (real@example.com) ##{user.id}", pf_user_option_label(masked)
    end

    test 'pf_raw_user_attribute falls back to the reader when the raw column is blank' do
      user = create_user(name: '   ')
      composing = ComposingReaderUser.find(user.id)

      assert_equal 'Composed Reader', pf_raw_user_attribute(composing, :name)
    end

    test 'pf_raw_user_attribute returns nil for attributes that are neither methods nor columns' do
      user = create_user

      assert_nil pf_raw_user_attribute(user, :not_a_column)
    end

    # Review of the round-7 fixes (P2-7): a marker the caller did not pass
    # (a stored value interpolated as text that holds one) raised KeyError —
    # a 500 for the page. It is left as written, escaped.
    test 'pf_t_markup leaves a marker it was not given as written' do
      out = pf_t_markup(set: tag.b('S')) { |held| "#{held[:set]} and \u0001other\u0001 <i>" }

      assert_equal "<b>S</b> and \u0001other\u0001 &lt;i&gt;", out
      assert_predicate out, :html_safe?
    end

    test 'pf_raw_user_attribute returns nil for non-ActiveRecord users without the method' do
      assert_nil pf_raw_user_attribute(BareUser.new(11), :name)
    end
  end
end
