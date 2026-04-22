# frozen_string_literal: true

module Indexmap
  class IndexNowConfiguration
    DEFAULT_ENDPOINT = "https://api.indexnow.org"
    DEFAULT_MAX_URLS_PER_REQUEST = 500

    attr_writer :dry_run, :endpoint, :key, :key_path, :max_urls_per_request

    def dry_run?
      value = resolve(@dry_run)
      value == true || value.to_s == "1"
    end

    def endpoint
      value = resolve(@endpoint)
      value.to_s.strip.empty? ? DEFAULT_ENDPOINT : value
    end

    def key
      resolve(@key)
    end

    def key_path(public_path:, key: self.key)
      configured_path = resolve(@key_path)
      return Pathname(configured_path) unless configured_path.to_s.strip.empty?
      return if key.to_s.strip.empty?

      Pathname(public_path).join("#{key}.txt")
    end

    def max_urls_per_request
      value = resolve(@max_urls_per_request)
      return DEFAULT_MAX_URLS_PER_REQUEST if value.nil?

      value.to_i
    end

    private

    def resolve(value)
      value.respond_to?(:call) ? value.call : value
    end
  end
end
