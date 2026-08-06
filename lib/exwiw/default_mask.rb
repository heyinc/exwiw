# frozen_string_literal: true

require "date"

module Exwiw
  # The `replace_with` value safe mode attaches to a newly discovered column.
  #
  # Only types a constant can safely stand in for are masked: a default the
  # column cannot hold would fail the restore the dump feeds, which is worse
  # than exporting the column while its `needs_mask_decision` flag keeps the
  # change from being merged.
  module DefaultMask
    FIXED_DATE = "2000-01-01"
    FIXED_TIME = "2000-01-01 00:00:00"
    EMPTY_JSON = "{}"

    # Skip the mask when the column is too short to hold `masked-<primary key>`
    # for a realistic key; the rendered length is only known per row at dump time.
    MIN_TEXT_LIMIT = 20
    MIN_EMAIL_LIMIT = 40

    module_function

    # The default mask for a column, or nil when no safe constant fits it.
    # `primary_key` is what keeps a text mask unique per row, so without one text
    # is left unmasked too. Under a unique index (`unique`) only a mask that
    # varies per row is allowed, or every row would collide on restore.
    def for(name:, type:, limit:, primary_key:, array: false, unique: false, column_default: nil)
      return nil if array

      mask =
        case type
        when :string, :text then text_mask(name, limit, primary_key)
        else constant_mask(type, column_default)
        end

      return nil if mask.nil?
      return nil if unique && !varies_per_row?(mask, primary_key)

      mask
    end

    # The column's own default wins over the per-type constant: it is a value the
    # column provably holds, and it is what the application treats as neutral, so
    # masking a `default: true` flag does not silently turn the feature off for
    # every row. A default computed by the database (`now()`) is not a constant
    # and arrives here as nil, so it falls through.
    def constant_mask(type, column_default)
      from_default = scalar_default(column_default)
      return from_default unless from_default.nil?

      case type
      when :integer, :decimal, :float then 0
      when :boolean then false
      when :date then FIXED_DATE
      when :datetime, :timestamp, :time then FIXED_TIME
      when :json, :jsonb then EMPTY_JSON
      end
    end

    # A default as a value `replace_with` accepts, or nil when it is not one.
    def scalar_default(value)
      case value
      when nil then nil
      when true, false, Integer, Float, String then value
      when Numeric then value.to_f
      when Time, DateTime then value.strftime("%Y-%m-%d %H:%M:%S")
      when Date then value.strftime("%Y-%m-%d")
      when Hash, Array then value.to_json
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

    def varies_per_row?(mask, primary_key)
      mask.is_a?(String) && mask.include?("{#{primary_key}}")
    end
  end
end
