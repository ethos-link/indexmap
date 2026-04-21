# frozen_string_literal: true

module Indexmap
  class Configuration
    VALID_FORMATS = %i[index single_file].freeze

    attr_writer :base_url, :entries, :format, :index_filename, :public_path, :sections

    def initialize
      @format = :index
      @index_filename = "sitemap.xml"
    end

    def base_url
      resolve(@base_url)
    end

    def entries
      Array(resolve(@entries))
    end

    def format
      value = resolve(@format)
      value.nil? ? :index : value.to_sym
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

      unless VALID_FORMATS.include?(format)
        raise ConfigurationError, "Indexmap format must be one of: #{VALID_FORMATS.join(", ")}"
      end

      if format == :single_file
        raise ConfigurationError, "Indexmap entries are not configured" if entries.empty?
      elsif sections.empty?
        raise ConfigurationError, "Indexmap sections are not configured" if sections.empty?
      end

      Writer.new(
        entries: entries,
        format: format,
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
