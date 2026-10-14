# frozen_string_literal: true

module PermissionForge
  module Admin
    # Display name / email / initials for a host-app user in the admin UI.
    #
    # Honors config.user_label_formatter for the name. Otherwise tries :name,
    # :full_name, :display_name, then composes first_name/last_name (or firstname/lastname). Attribute
    # reads go raw-column-first (read_attribute_before_type_cast) so
    # MaskedAttributes on the User model never garbles admin lists; virtual
    # attributes and blank columns fall back to the public reader.
    class PersonLabel
      NAME_METHODS = %i[name full_name display_name].freeze

      def initialize(user, configuration: PermissionForge.configuration)
        @user = user
        @configuration = configuration
      end

      def name
        @name ||= formatted_name || default_name || email || fallback
      end

      def email
        @email ||= raw_value(:email).to_s.strip.presence
      end

      # Email shown under the name — omitted when the name already is the email.
      def secondary
        email unless email == name
      end

      def initials
        initial_letters(name.to_s.scan(/[[:alnum:]]+/)).join.upcase.presence || '?'
      end

      # Lower-cased "name email" for in-memory search.
      def search_text
        "#{name} #{email}".downcase
      end

      def first_name
        name.to_s.split(/\s+/).first.presence || name
      end

      private

      # First letters of the first and last word, or the first two letters of a single word.
      def initial_letters(words)
        words.size > 1 ? [words.first[0], words.last[0]] : [words.first.to_s[0, 2]]
      end

      def formatted_name
        formatter = @configuration.user_label_formatter
        return nil unless formatter

        formatter.call(@user).to_s.strip.presence
      end

      def default_name
        NAME_METHODS.each do |method|
          value = raw_value(method).to_s.strip
          return value unless value.empty?
        end
        composed(:first_name, :last_name) || composed(:firstname, :lastname)
      end

      def composed(first, last)
        [raw_value(first), raw_value(last)].compact.map { |part| part.to_s.strip }.reject(&:empty?).join(' ').presence
      end

      def fallback
        I18n.t('permission_forge.shared.user_fallback', id: @user.id)
      end

      def raw_value(attr)
        attr_name = attr.to_s
        if readable_column?(attr_name)
          value = @user.read_attribute_before_type_cast(attr_name)
          return value if value.to_s.strip.present?
        end
        @user.try(attr)
      end

      # True when attr_name is a loaded column on an AR-like user (guards
      # partial SELECTs from a custom user_list_resolver).
      def readable_column?(attr_name)
        klass = @user.class
        klass.respond_to?(:column_names) && klass.column_names.include?(attr_name) &&
          @user.respond_to?(:read_attribute_before_type_cast) &&
          (!@user.respond_to?(:has_attribute?) || @user.has_attribute?(attr_name))
      end
    end
  end
end
