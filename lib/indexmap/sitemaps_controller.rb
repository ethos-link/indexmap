# frozen_string_literal: true

require "indexmap"
require "rails"
require "action_controller"

class Indexmap::SitemapsController < ActionController::Base
  def show
    configuration = Indexmap.configuration
    storage = configuration.storage
    unless storage.respond_to?(:metadata) && storage.respond_to?(:open)
      raise Indexmap::ConfigurationError, "Sitemap delivery requires storage metadata and open capabilities"
    end
    path = request.path_parameters
    filename = [path[:prefix], path.fetch(:filename)].compact.join("/")
    allowed = configuration.output_names.any? do |name|
      output = configuration.output_for(name)
      root = output.index_filename
      next true if filename == root
      next false unless output.atomic

      publication = Indexmap::Publication.new(root: root)
      version = publication.generation(filename)
      next false unless version
      next true if storage.exist?(publication.archive(version))
      next false unless storage.exist?(root)

      metadata = storage.metadata(root)
      active = Rails.cache.fetch(["indexmap-generation", storage.public_url(root), metadata.fetch(:etag)], expires_in: 1.hour) do
        publication.current_generation(storage)
      end
      version == active
    end
    return head :not_found unless allowed && storage.exist?(filename)

    metadata = storage.metadata(filename)
    if Indexmap::Publication.immutable?(filename)
      expires_in 1.year, public: true, immutable: true
    else
      expires_in 10.minutes, public: true, stale_while_revalidate: 1.hour
    end
    fresh_when etag: metadata.fetch(:etag), last_modified: metadata.fetch(:last_modified), public: true, template: false
    return if performed?

    response.content_type = "application/xml"
    response_body = Enumerator.new do |stream|
      storage.open(filename) do |io|
        while (chunk = io.read(64 * 1024))
          stream << chunk
        end
      end
    end
    self.response_body = response_body
  rescue Errno::ENOENT
    head :not_found
  end
end
