# frozen_string_literal: true

require "nokogiri"

module Indexmap
  class TaskRunner
    def initialize(configuration: Indexmap.configuration)
      @configuration = configuration
    end

    def create
      written_files = Indexmap.create(configuration: configuration)
      index_now_key_filename = write_index_now_key if configuration.index_now.write_key_file?
      configuration.run_after_create_callbacks

      {files: written_files.map(&:to_s), written_files: written_files, index_now_key_filename: index_now_key_filename}
    end

    def format
      sitemap_files.each do |filename|
        content = storage.read(filename)
        document = Nokogiri::XML(
          content,
          nil,
          nil,
          Nokogiri::XML::ParseOptions::DEFAULT_XML | Nokogiri::XML::ParseOptions::NOBLANKS
        )
        save_options = Nokogiri::XML::Node::SaveOptions::FORMAT | Nokogiri::XML::Node::SaveOptions::AS_XML

        storage.write(filename, document.to_xml(indent: 2, save_with: save_options), content_type: "application/xml")
      end

      sitemap_files
    end

    def validate
      Validator.new(configuration: configuration).validate!
      sitemap_files
    end

    def write_index_now_key(generate_if_missing: false)
      pinger = Pinger::IndexNow.new(configuration: configuration)
      return pinger.ensure_key_file if generate_if_missing

      pinger.write_key_file
    end

    def storage
      configuration.storage
    end

    private

    attr_reader :configuration

    def default_output
      configuration.output_for(:default)
    end

    def sitemap_files
      storage.list(prefix: "sitemap", suffix: ".xml")
    end
  end
end
