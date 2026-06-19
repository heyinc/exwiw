# frozen_string_literal: true

require "json"

module Exwiw
  # MongoDB Relaxed Extended JSON encoder for a single dumped document.
  #
  # `encode` is the one entry point. When the optional native extension compiled
  # (the common case once `gem install exwiw` builds it), it emits the line in a
  # single C tree-walk; otherwise it falls back to the pure-Ruby path. Both are
  # byte-for-byte identical — the native path delegates every value it does not
  # format itself back to `encode_fragment` (see ext/exwiw/ext_json/ext_json.c).
  module ExtJson
    module_function

    # Pure-Ruby encoder for one value, identical to the historical
    # `JSON.generate(doc.as_extended_json(mode: :relaxed))`. Used both as the
    # whole-document fallback and as the native path's per-value delegate, so the
    # two paths cannot diverge.
    def encode_fragment(value)
      JSON.generate(value.respond_to?(:as_extended_json) ? value.as_extended_json(mode: :relaxed) : value)
    end

    begin
      require "exwiw/ext_json_native" # defines Exwiw::ExtJson.encode_native
      def encode(doc) = encode_native(doc)
    rescue LoadError
      # No compiled extension (JRuby/TruffleRuby, or a host where the build
      # failed): keep exwiw working as a pure-Ruby gem.
      def encode(doc) = encode_fragment(doc)
    end
  end
end
