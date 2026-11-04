# frozen_string_literal: true

require "test_helper"
require "indexmap/sitemaps_controller"
require "rack/mock"
require "active_support/cache"

class IndexmapSitemapsControllerTest < Minitest::Test
  def test_serves_only_published_and_retained_artifacts_without_source_queries
    Dir.mktmpdir do |directory|
      Indexmap.reset!
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      config = Indexmap.configuration
      config.base_url = "https://example.com"
      config.storage = Indexmap::Storage::Filesystem.new(path: directory)
      config.atomic = true
      config.sections = -> { [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: [{loc: "https://example.com/page"}])] }
      old = Indexmap.create.first
      child = Indexmap.create.first
      unpublished = Indexmap::Publication.new(root: "sitemap.xml").filename(generation: "f" * 32, section: 1, part: 1)
      config.storage.write(unpublished, "not published")
      config.sections = -> { raise "must not query source content" }
      routes = ActionDispatch::Routing::RouteSet.new
      routes.draw do
        get "/sitemap.xml", to: Indexmap::SitemapsController.action(:show), defaults: {filename: "sitemap.xml"}, format: false
        get "/:filename", to: Indexmap::SitemapsController.action(:show), constraints: {filename: /[^\/]+/}, format: false
      end
      client = Rack::MockRequest.new(Rack::Head.new(routes))
      response = client.get("/#{child}")
      assert_equal 200, response.status
      assert_includes response.body, "https://example.com/page"
      assert_match "application/xml", response["content-type"]
      assert_includes response["cache-control"], "immutable"
      assert_nil response["set-cookie"]
      assert_equal 200, client.get("/#{old}").status
      assert_equal 404, client.get("/#{unpublished}").status
      assert_equal 404, client.get("/robots.txt").status
      assert_equal 200, client.get("/#{child}?prefix=../../").status
      config.storage.define_singleton_method(:open) { |_filename, &_block| raise "must not download body" }
      cached = client.get("/#{child}", "HTTP_IF_NONE_MATCH" => response["etag"])
      assert_equal 304, cached.status
      assert_empty cached.body
      head = client.head("/#{child}")
      assert_equal 200, head.status
      assert_empty head.body
    ensure
      Indexmap.reset!
    end
  end
end
