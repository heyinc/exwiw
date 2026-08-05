# frozen_string_literal: true

module Exwiw
  # The `replace_with` value `schema:generate`'s safe mode attaches to a newly
  # discovered column (see SchemaGenerator#build_tables_for).
  #
  # Only types a constant can safely stand in for are masked. A default that the
  # target column cannot hold — a text literal in a `uuid` column, or a value
  # longer than a short `varchar` — would fail the restore the dump feeds, which
  # is worse than exporting the column while its `needs_mask_decision` flag keeps
  # the change from being merged. So an unmaskable type is flagged and left
  # as-is rather than masked with something invalid.
  module DefaultMask
    FIXED_DATE = "2000-01-01"
    FIXED_TIME = "2000-01-01 00:00:00"
    EMPTY_JSON = "{}"

    # A masked text value is `masked-<primary key>`, so it stays unique under a
    # unique index. Skip the mask when the column is too short to hold that for
    # a realistic key, since the length is only known per row at dump time.
    MIN_TEXT_LIMIT = 20
    MIN_EMAIL_LIMIT = 40

    module_function

    # The default mask for a column, or nil when the type has no safe constant.
    # `primary_key` is the template reference that keeps text masks unique; with
    # no single primary key there is nothing to key them on, so text is left
    # unmasked too.
    def for(name:, type:, limit:, primary_key:)
      case type
      when :integer, :decimal, :float then 0
      when :boolean then false
      when :date then FIXED_DATE
      when :datetime, :timestamp, :time then FIXED_TIME
      when :json, :jsonb then EMPTY_JSON
      when :string, :text then text_mask(name, limit, primary_key)
      end
    end

    def text_mask(name, limit, primary_key)
      return nil if primary_key.nil?

      if name.to_s.include?("mail")
        return nil if limit && limit < MIN_EMAIL_LIMIT

        "masked-{#{primary_key}}@example.com"
      else
        return nil if limit && limit < MIN_TEXT_LIMIT

        "masked-{#{primary_key}}"
      end
    end
  end
end
