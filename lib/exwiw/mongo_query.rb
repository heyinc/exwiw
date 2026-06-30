# frozen_string_literal: true

module Exwiw
  module MongoQuery
    # `timeout_ms` is the per-collection, server-enforced operation timeout (CSOT)
    # applied when this query runs; nil falls back to the client-wide global
    # (ConnectionConfig#mongodb_query_timeout_ms) or, if that is also unset, no
    # timeout. Omitted from #to_h when nil so the historical 4-key query shape is
    # unchanged for collections without a timeout.
    Find = Struct.new(:collection, :primary_key, :filter, :projection, :timeout_ms, keyword_init: true) do
      def to_h
        {
          collection: collection,
          primary_key: primary_key,
          filter: filter,
          projection: projection,
        }.tap { |h| h[:timeout_ms] = timeout_ms unless timeout_ms.nil? }
      end
    end
  end
end
