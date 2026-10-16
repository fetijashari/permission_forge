# frozen_string_literal: true

module PermissionForge
  module Admin
    # Display name / email / initials for a host-app user in the admin UI.
    #
    # Honors config.user_label_formatter for the name. Otherwise tries :name,
    # :full_name, :display_name, then composes first_name/last_name (or firstname/lastname), then
    # the email (EMAIL_ATTRIBUTES: `email`, or Rails 8's `email_address`). Attribute
    # reads go raw-column-first (read_attribute_before_type_cast) so
    # MaskedAttributes on the User model never garbles admin lists; virtual
    # attributes and blank columns fall back to the public reader. A column
    # the model encrypts (`encrypts :email`) is read decrypted through its
    # attribute type (PermissionForge::EncryptedAttributes), never as the
    # ciphertext it stores — for the admin's display, which is never cached.
    # `decrypt: false` (the default profile_builder, whose profile is cached
    # with the permission hash in the cache store) reads such a column as
    # nil instead: neither its ciphertext nor its plaintext.
    class PersonLabel
      NAME_METHODS = %i[name full_name display_name].freeze
      # The one definition of "the user's email attribute", in order: `email`,
      # then `email_address` (the column Rails 8's authentication generator
      # creates). Labels, people search, bulk matching and the default
      # profile_builder all read it from here.
      EMAIL_ATTRIBUTES = %i[email email_address].freeze

      # @param user [Object]
      # @param configuration [PermissionForge::Configuration]
      # @param decrypt [Boolean] false: an encrypted column reads as nil
      def initialize(user, configuration: PermissionForge.configuration, decrypt: true)
        @user = user
        @configuration = configuration
        @decrypt = decrypt
      end

      # A user attribute read raw-column-first (read_attribute_before_type_cast,
      # past MaskedAttributes), the public reader for a virtual attribute or a
      # blank column; nil when the user has neither. The one definition for the
      # admin's labels (pf_raw_user_attribute) and the default profile_builder.
      #
      # @param user [Object]
      # @param attr [Symbol, String]
      # @return [Object, nil]
      def self.raw_value(user, attr)
        new(user).raw_value(attr)
      end

      # @see .raw_value
      def raw_value(attr)
        attr_name = attr.to_s
        if readable_column?(attr_name)
          value = column_value(attr_name)
          return value if value.to_s.strip.present? || encrypted?(attr_name)
        end
        @user.try(attr)
      end

      def name
        @name ||= formatted_name || default_name || email || fallback
      end

      # The first EMAIL_ATTRIBUTES value present, stripped.
      def email
        @email ||= first_present(EMAIL_ATTRIBUTES)
      end

      # Email shown under the name — omitted when the name already is the email.
      def secondary
        email unless email == name
      end

      # Two letters for the avatar: the first and last word of a name ("AK"),
      # or the first two letters of a single word. A label that is the email
      # takes them from its local part ("dave@acme.test" => "DA"), never from
      # the domain.
      def initials
        initial_letters(initials_source.scan(/[[:alnum:]]+/)).join.upcase.presence || '?'
      end

      # Whether the label is the "User #<id>" fallback: neither a name nor an email.
      def fallback?
        name == fallback
      end

      # Lower-cased "name email" for in-memory search.
      def search_text
        "#{name} #{email}".downcase
      end

      # The first word of a person's name, for sentences ("What Ana can do").
      # A label that is not a name (the email, or the "User #2" fallback) is
      # used whole: its first word would read as a placeholder ("User").
      def first_name
        return name unless personal_name?

        name.to_s.split(/\s+/).first.presence || name
      end

      private

      # Whether the label comes from a name (formatter or name attributes),
      # not from the email or the id fallback.
      def personal_name?
        label = name
        label != email && label != fallback
      end

      def initials_source
        label = name.to_s
        label == email ? label.split('@').first.to_s : label
      end

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
        first_present(NAME_METHODS) || composed(:first_name, :last_name) || composed(:firstname, :lastname)
      end

      def first_present(attrs)
        attrs.each do |attr|
          value = raw_value(attr).to_s.strip
          return value unless value.empty?
        end
        nil
      end

      def composed(first, last)
        [raw_value(first), raw_value(last)].compact.map { |part| part.to_s.strip }.reject(&:empty?).join(' ').presence
      end

      def fallback
        I18n.t('permission_forge.shared.user_fallback', id: @user.id)
      end

      # The stored value; decrypted for an encrypted column (nil when this
      # application cannot decrypt it: the reader would raise), nil for one
      # under `decrypt: false`.
      def column_value(attr_name)
        value = @user.read_attribute_before_type_cast(attr_name)
        return value if value.nil? || !encrypted?(attr_name)

        PermissionForge::EncryptedAttributes.decrypt(@user.class, attr_name, value) if @decrypt
      end

      def encrypted?(attr_name)
        PermissionForge::EncryptedAttributes.encrypted?(@user.class, attr_name)
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
