# frozen_string_literal: true

require "tmpdir"
require "securerandom"

module Indexmap
  class Creator
    ValidationConfiguration = Struct.new(:base_url, :index_filename, :storage)

    attr_reader :sitemaps

    def initialize(output:, storage: nil)
      @output = output
      @storage = storage
    end

    def create
      atomic = output.atomic
      root = output.index_filename
      raise ConfigurationError, "Root filename uses the reserved immutable namespace" if Publication.immutable?(root)
      if atomic && !(storage.respond_to?(:revision) && storage.respond_to?(:publish))
        raise ConfigurationError, "Atomic publication requires storage revision and publish capabilities"
      end
      expected = storage.revision(root) if atomic
      writer = output.writer(generation: atomic ? SecureRandom.hex(16) : nil)
      files = []
      Dir.mktmpdir("indexmap-build") do |directory|
        staged = Storage::Filesystem.new(path: directory)
        writer.each_file do |file|
          raise ConfigurationError, "Duplicate sitemap filename: #{file.filename}" if staged.exist?(file.filename)

          staged.write(file.filename, file.body, content_type: file.content_type)
          files << file.filename
        end
        Validator.new(configuration: ValidationConfiguration.new(
          base_url: output.base_url, index_filename: root, storage: staged
        )).validate!(collect: false)
        if atomic
          storage.publish(staged, files: files, root: root, expected: expected)
        else
          files.each do |filename|
            if storage.respond_to?(:write_io)
              staged.open(filename) { |io| storage.write_io(filename, io, content_type: "application/xml") }
            else
              storage.write(filename, staged.read(filename), content_type: "application/xml")
            end
          end
        end
      end
      @sitemaps = files.map do |filename|
        location = storage.respond_to?(:public_url) ? storage.public_url(filename) : filename
        {filename: filename, location: location, link_count: writer.counts.fetch(filename)}
      end
      files
    end

    private

    attr_reader :output

    def storage
      @storage ||= output.storage
    end
  end
end
