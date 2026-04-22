# frozen_string_literal: true

require "nokogiri"

module Indexmap
  class TaskRunner
    def initialize(configuration: Indexmap.configuration)
      @configuration = configuration
    end

    def create
      remove_existing_sitemap_files
      configuration.writer.write
      write_index_now_key
    end

    def format
      sitemap_files.each do |file_path|
        content = File.read(file_path)
        document = Nokogiri::XML(
          content,
          nil,
          nil,
          Nokogiri::XML::ParseOptions::DEFAULT_XML | Nokogiri::XML::ParseOptions::NOBLANKS
        )
        save_options = Nokogiri::XML::Node::SaveOptions::FORMAT | Nokogiri::XML::Node::SaveOptions::AS_XML

        File.write(file_path, document.to_xml(indent: 2, save_with: save_options))
      end
    end

    def validate
      Validator.new(configuration: configuration).validate!
    end

    def write_index_now_key
      Pinger::IndexNow.new(configuration: configuration).write_key_file
    end

    private

    attr_reader :configuration

    def sitemap_files
      Dir.glob(configuration.public_path.join("sitemap*.xml"))
    end

    def remove_existing_sitemap_files
      Dir.glob(configuration.public_path.join("sitemap*.xml*")).each do |file_path|
        File.delete(file_path)
      end
    end
  end
end
