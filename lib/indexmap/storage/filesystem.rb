# frozen_string_literal: true

require "uri"

module Indexmap
  module Storage
    class Filesystem
      DEFAULT_CONTENT_TYPE = "application/xml"

      def initialize(path:, public_url: nil)
        @path = Pathname(path)
        @public_url_base = public_url
      end

      def write(filename, body, content_type: DEFAULT_CONTENT_TYPE)
        target = path_for(filename)
        target.dirname.mkpath
        target.write(body.to_s)

        File.new(
          filename: normalize_filename(filename),
          body: body.to_s,
          content_type: content_type || DEFAULT_CONTENT_TYPE
        )
      end

      def read(filename)
        path_for(filename).read(encoding: "UTF-8")
      end

      def exist?(filename)
        path_for(filename).file?
      end

      def list(prefix: nil, suffix: nil)
        path.glob("*").select(&:file?).filter_map do |file|
          filename = file.basename.to_s
          next if prefix && !filename.start_with?(prefix)
          next if suffix && !filename.end_with?(suffix)

          filename
        end.sort
      end

      def delete(filename)
        path_for(filename).delete if exist?(filename)
      end

      def public_url(filename)
        return normalize_filename(filename) if public_url_base.to_s.strip.empty?

        URI.join("#{public_url_base.to_s.delete_suffix("/")}/", normalize_filename(filename)).to_s
      end

      def inspect
        "#<#{self.class.name} path=#{path}>"
      end

      private

      attr_reader :path, :public_url_base

      def path_for(filename)
        path.join(normalize_filename(filename))
      end

      def normalize_filename(filename)
        normalized = Pathname(filename.to_s).cleanpath
        if normalized.absolute? || normalized.to_s.start_with?("../") || normalized.to_s == ".."
          raise ArgumentError, "Storage filename must be relative: #{filename.inspect}"
        end

        normalized.to_s
      end
    end
  end
end
