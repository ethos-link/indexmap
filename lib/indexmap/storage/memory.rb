# frozen_string_literal: true

require "uri"

module Indexmap
  module Storage
    class Memory
      DEFAULT_CONTENT_TYPE = "application/xml"

      def initialize(files = [], public_url: nil)
        @files = {}
        @public_url_base = public_url
        Array(files).each do |file|
          write(file.filename, file.body, content_type: file.content_type)
        end
      end

      def write(filename, body, content_type: DEFAULT_CONTENT_TYPE)
        normalized = normalize_filename(filename)
        files[normalized] = File.new(
          filename: normalized,
          body: body.to_s,
          content_type: content_type || DEFAULT_CONTENT_TYPE
        )
      end

      def read(filename)
        files.fetch(normalize_filename(filename)).body
      end

      def exist?(filename)
        files.key?(normalize_filename(filename))
      end

      def list(prefix: nil, suffix: nil)
        files.keys.select do |filename|
          (prefix.nil? || filename.start_with?(prefix)) &&
            (suffix.nil? || filename.end_with?(suffix))
        end.sort
      end

      def delete(filename)
        files.delete(normalize_filename(filename))
      end

      def public_url(filename)
        return normalize_filename(filename) if public_url_base.to_s.strip.empty?

        URI.join("#{public_url_base.to_s.delete_suffix("/")}/", normalize_filename(filename)).to_s
      end

      private

      attr_reader :files, :public_url_base

      def normalize_filename(filename)
        filename.to_s
      end
    end
  end
end
