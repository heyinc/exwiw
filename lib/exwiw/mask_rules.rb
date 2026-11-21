# frozen_string_literal: true

module Exwiw
  # The rules over a table's masks. `mask-update` enforces the primary key ones before it reads a row, and `schema
  # check` reports them all from the committed config. Each adapter class describes a loaded table for them with
  # `describe_masks`.
  module MaskRules
    # A column (MongoDB: a field path, embedded fields included) as the rules see it. `name` is the last path segment,
    # `masked` says a mask is declared, `safe` that it is NULL or a random expression (never for MongoDB), and `exempt`
    # that it is the primary key or a belongs_to foreign key, which exwiw never masks.
    Column = Data.define(:path, :name, :masked, :safe, :allow_guessable_credential, :allow_unmasked, :exempt)

    # A table (collection) as the rules see it. `selects_primary_key` is false when the SELECT would not read the key.
    Table = Data.define(:name, :primary_key, :selects_primary_key, :columns)

    # A name that looks like a credential: masking one to a guessable value defeats the mask. `encrypted` is left out, as
    # it says how a value is stored rather than what it is (DEFAULT_MASK_PATTERNS keeps it).
    CREDENTIAL_NAME = /password|digest|salt|secret|token|credential|passcode|api_key|access_key|private_?key|jwk/i

    # Names that match a pattern but cannot hold the value it is after: a timestamp (`email_updated_at`,
    # `access_token_expires_at`).
    EXCLUDED_NAME = /_at\z/i

    # Names that look like they hold sensitive data, in the spirit of Rails' filter_parameters.
    DEFAULT_MASK_PATTERNS = [
      # Credentials, one-time passwords, and what is stored encrypted
      CREDENTIAL_NAME,
      /(^|_)otp(_|$)/i,
      /encrypted/i,
      # Contact details
      /e_?mail/i,
      # `mobile` only as a whole name (or `mobile_number` ...), so that `mobile_order_count` does not match.
      /phone|(^|_)mobile(_?(phone|number|tel))?$|(^|_)(tel|fax)(_|$)/i,
      /address/i,
      /(^|_)(zip|postal)/i,
      # Personal attributes
      /birth/i,
      /(first|last|middle|full|given|family)_?name/i,
      # Government and card numbers
      /(^|_)(ssn|cvv|cvc)(_|$)/i,
      /card_?number/i,
    ].freeze

    module_function

    # @param table [Exwiw::MaskRules::Table]
    # @return [Boolean] whether any column declares a mask
    def masked?(table)
      table.columns.any?(&:masked)
    end

    # @param table [Exwiw::MaskRules::Table]
    # @return [Boolean] whether the primary key, which addresses the rows to update, is masked
    def masks_primary_key?(table)
      table.columns.any? { |column| column.masked && column.path == table.primary_key }
    end

    # @param table [Exwiw::MaskRules::Table]
    # @param patterns [Array<Regexp>] the credential name patterns
    # @return [Array<String>] the credential-looking paths masked to a guessable value, allowed or not
    def guessable_credentials(table, patterns = [CREDENTIAL_NAME])
      table.columns.select do |column|
        column.masked && !column.safe && !column.name.match?(EXCLUDED_NAME) &&
          patterns.any? { |pattern| column.path.match?(pattern) }
      end.map(&:path)
    end

    # @param table [Exwiw::MaskRules::Table]
    # @param patterns [Array<Regexp>] the credential name patterns
    # @return [Array<String>] the paths of #guessable_credentials that do not set `allow_guessable_credential`
    def unaccepted_credentials(table, patterns = [CREDENTIAL_NAME])
      guessable_credentials(table, patterns) - guessable_allowances(table)
    end

    # @param table [Exwiw::MaskRules::Table]
    # @param patterns [Array<Regexp>] the credential name patterns
    # @return [Array<String>] the paths that set `allow_guessable_credential` but are not among #guessable_credentials
    def stray_guessable_allowances(table, patterns = [CREDENTIAL_NAME])
      guessable_allowances(table) - guessable_credentials(table, patterns)
    end

    # @param name [String] a column name, or the last segment of a field path
    # @param patterns [Array<Regexp>]
    # @return [Boolean]
    def sensitive_name?(name, patterns = DEFAULT_MASK_PATTERNS)
      !name.match?(EXCLUDED_NAME) && patterns.any? { |pattern| name.match?(pattern) }
    end

    # @param table [Exwiw::MaskRules::Table]
    # @param patterns [Array<Regexp>] the mask patterns
    # @return [Array<String>] the paths whose name looks sensitive but that are neither masked, exempt nor `allow_unmasked`
    def unmasked_sensitive(table, patterns = DEFAULT_MASK_PATTERNS)
      table.columns.select do |column|
        !column.masked && !column.exempt && !column.allow_unmasked && sensitive_name?(column.name, patterns)
      end.map(&:path)
    end

    # @param table [Exwiw::MaskRules::Table]
    # @param patterns [Array<Regexp>] the mask patterns
    # @return [Array<Array(String, Symbol)>] each path that sets `allow_unmasked` with nothing to allow, and why:
    #   `:masked`, `:exempt` (primary key or belongs_to foreign key) or `:not_sensitive`
    def stray_unmasked_allowances(table, patterns = DEFAULT_MASK_PATTERNS)
      table.columns.select(&:allow_unmasked).filter_map do |column|
        reason =
          if column.masked then :masked
          elsif column.exempt then :exempt
          elsif !sensitive_name?(column.name, patterns) then :not_sensitive
          end
        [column.path, reason] if reason
      end
    end

    private_class_method def guessable_allowances(table)
      table.columns.select(&:allow_guessable_credential).map(&:path)
    end
  end
end
