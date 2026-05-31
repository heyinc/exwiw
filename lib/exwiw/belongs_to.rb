# frozen_string_literal: true

module Exwiw
  class BelongsTo
    include Serdes

    attribute :foreign_key, String
    attribute :table_name, String
    # polymorphic 関連の場合のみ設定される。`foreign_type` は型を格納するカラム名
    # (例: `reviewable_type`)、`type_value` はそのカラムに入る値 (例: `"Product"`)。
    # 非 polymorphic の belongs_to では両方とも nil。
    attribute :foreign_type, optional(String), skip_serializing_if_nil: true
    attribute :type_value, optional(String), skip_serializing_if_nil: true

    def self.from_symbol_keys(hash)
      from(hash.transform_keys(&:to_s))
    end

    def polymorphic?
      !foreign_type.nil?
    end

    def to_hash
      super.compact
    end
  end
end
