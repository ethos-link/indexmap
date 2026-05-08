# frozen_string_literal: true

require "nokogiri"

module Indexmap
  class Creator
    ValidationConfiguration = Struct.new(:base_url, :index_filename, :storage, keyword_init: true)

    def initialize(output:)
      @output = output
    end

    def create
      files = format(write)
      validate(files)
      publish(files)
      files.map(&:filename)
    end

    private

    attr_reader :output

    def write
      output.writer.write
    end

    def format(files)
      files.map do |file|
        document = Nokogiri::XML(
          file.body,
          nil,
          nil,
          Nokogiri::XML::ParseOptions::DEFAULT_XML | Nokogiri::XML::ParseOptions::NOBLANKS
        )
        save_options = Nokogiri::XML::Node::SaveOptions::FORMAT | Nokogiri::XML::Node::SaveOptions::AS_XML

        Storage::File.new(
          filename: file.filename,
          body: document.to_xml(indent: 2, save_with: save_options),
          content_type: file.content_type
        )
      end
    end

    def validate(files)
      Validator.new(
        configuration: ValidationConfiguration.new(
          base_url: output.base_url,
          index_filename: output.index_filename,
          storage: Storage::Memory.new(files)
        )
      ).validate!
    end

    def publish(files)
      files.each do |file|
        output.storage.write(file.filename, file.body, content_type: file.content_type)
      end
    end
  end
end
