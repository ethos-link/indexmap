# frozen_string_literal: true

require "pathname"
require "uri"

module Indexmap
  module Path
    INDEX_FILENAME = "sitemap.xml"
    LEGACY_FILENAME = "sitemap_index.xml"

    module_function

    def canonical_public_path(public_path: default_public_path_root, index_filename: default_index_filename)
      Pathname(public_path).join(index_filename)
    end

    def existing_public_path(public_path: default_public_path_root, index_filename: default_index_filename, legacy_filename: LEGACY_FILENAME)
      index_path = canonical_public_path(public_path: public_path, index_filename: index_filename)
      return index_path if index_path.exist?

      Pathname(public_path).join(legacy_filename)
    end

    def canonical_url(base_url, index_filename: default_index_filename)
      URI.join(base_url, "/#{index_filename}").to_s
    end

    def default_index_filename
      Indexmap.configuration.index_filename.presence || INDEX_FILENAME
    rescue
      INDEX_FILENAME
    end

    def default_public_path_root
      if defined?(Rails)
        Rails.public_path
      else
        Pathname("public")
      end
    end
  end
end
