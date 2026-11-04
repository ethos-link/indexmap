# frozen_string_literal: true

require "digest"
require "uri"

module Indexmap
  class Publication
    def self.immutable?(filename)
      File.basename(filename).match?(/\Asitemap-[a-f0-9]{16}-[a-f0-9]{32}-[1-9]\d*-[1-9]\d*\.xml\z/)
    end

    def initialize(root:)
      @root = root
      @prefix = File.join(File.dirname(root), "sitemap-#{Digest::SHA256.hexdigest(root)[0, 16]}-").delete_prefix("./")
    end

    attr_reader :root, :prefix

    def filename(generation:, section:, part:)
      "#{prefix}#{generation}-#{section}-#{part}.xml"
    end

    def generation(filename)
      filename[/\A#{Regexp.escape(prefix)}([a-f0-9]{32})-[1-9]\d*-[1-9]\d*\.xml\z/, 1]
    end

    def child?(filename)
      !generation(filename).nil?
    end

    def archive(generation)
      "#{prefix}#{generation}-index.xml"
    end

    def current_generation(storage)
      return unless storage.exist?(root)

      metadata = storage.metadata(root)
      return metadata[:generation] if metadata.key?(:generation)

      result = nil
      storage.open(root) do |io|
        Nokogiri::XML::Reader.from_io(io, nil, nil, Nokogiri::XML::ParseOptions::NONET).each do |node|
          if node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT && node.local_name == "loc"
            element = Nokogiri::XML(node.outer_xml) { |options| options.strict.nonet }
            path = URI.parse(element.root.text).path
            candidate = File.join(File.dirname(root), File.basename(path)).delete_prefix("./")
            result = generation(candidate)
            break
          end
        end
      end
      result
    end

    def prune(storage, before:)
      return [] unless storage.exist?(root)

      current = current_generation(storage)
      files = storage.list(prefix: prefix, suffix: ".xml")
      deleted = []
      files.each do |filename|
        match = filename.match(/\A#{Regexp.escape(prefix)}([a-f0-9]{32})-index\.xml\z/)
        next unless match && match[1] != current && storage.metadata(filename).fetch(:last_modified) < before

        block_given? ? yield(filename) : storage.delete(filename)
        deleted << filename
      end
      files.each do |filename|
        version = generation(filename)
        next unless version && version != current && !storage.exist?(archive(version))
        next unless storage.metadata(filename).fetch(:last_modified) < before

        block_given? ? yield(filename) : storage.delete(filename)
        deleted << filename
      end
      deleted
    end
  end
end
