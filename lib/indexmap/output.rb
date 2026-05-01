# frozen_string_literal: true

module Indexmap
  class Output
    VALID_FORMATS = %i[index single_file].freeze

    attr_writer :base_url, :entries, :format, :index_filename, :public_path, :sections

    def initialize(configuration:)
      @configuration = configuration
    end

    def base_url
      resolve(@base_url) || configuration.base_url
    end

    def entries
      resolved_entries = resolve(@entries)

      Array(resolved_entries.nil? ? configuration.entries : resolved_entries)
    end

    def format
      value = resolve(@format) || configuration.format
      value.nil? ? :index : value.to_sym
    end

    def index_filename
      resolve(@index_filename) || configuration.index_filename
    end

    def public_path
      value = resolve(@public_path) || configuration.public_path
      Pathname(value)
    end

    def sections
      resolved_sections = resolve(@sections)

      Array(resolved_sections.nil? ? configuration.sections : resolved_sections)
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

    attr_reader :configuration

    def resolve(value)
      value.respond_to?(:call) ? value.call : value
    end
  end
end
