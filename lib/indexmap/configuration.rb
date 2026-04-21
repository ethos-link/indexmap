# frozen_string_literal: true

module Indexmap
  class Configuration
    attr_writer :base_url, :index_filename, :public_path, :sections

    def initialize
      @index_filename = "sitemap.xml"
    end

    def base_url
      resolve(@base_url)
    end

    def index_filename
      resolve(@index_filename)
    end

    def public_path
      value = resolve(@public_path)
      return Pathname("public") if value.nil?

      Pathname(value)
    end

    def sections
      Array(resolve(@sections))
    end

    def writer
      raise ConfigurationError, "Indexmap base_url is not configured" if base_url.to_s.strip.empty?
      raise ConfigurationError, "Indexmap sections are not configured" if sections.empty?

      Writer.new(
        sections: sections,
        public_path: public_path,
        base_url: base_url,
        index_filename: index_filename
      )
    end

    private

    def resolve(value)
      value.respond_to?(:call) ? value.call : value
    end
  end
end
