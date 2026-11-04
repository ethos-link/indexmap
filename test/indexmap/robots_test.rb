# frozen_string_literal: true

require "test_helper"
require "indexmap/robots_controller"
require "rack/mock"

class IndexmapRobotsTest < Minitest::Test
  def setup
    Indexmap.reset!
    Indexmap.configuration.base_url = "https://example.com"
  end

  def teardown
    Indexmap.reset!
  end

  def test_defaults_to_disallow_without_resolving_sitemap_data
    Indexmap.configuration.base_url = -> { raise "must not resolve" }
    Indexmap.configuration.sections = -> { raise "must not query" }
    Indexmap.configuration.storage = -> { raise "must not read storage" }
    assert_equal "User-agent: *\nDisallow: /\n", Indexmap.configuration.robots.body
  end

  def test_uses_explicit_indexability_and_the_configured_root
    indexable = true
    config = Indexmap.configuration
    config.index_filename = "sitemaps/main.xml"
    config.robots.indexable = -> { indexable }
    config.robots.groups = [{user_agent: ["*", "ExampleBot"], allow: ["/"], disallow: ["/admin/", "/search"]}]
    assert_includes config.robots.body, "Sitemap: https://example.com/sitemaps/main.xml"
    assert_includes config.robots.body, "Disallow: /admin/"
    assert_includes config.robots.body, "User-agent: ExampleBot"
    indexable = false
    assert_equal "User-agent: *\nDisallow: /\n", config.robots.body
  end

  def test_rejects_injected_directives_and_invalid_sitemap_urls
    config = Indexmap.configuration
    config.robots.indexable = true
    config.robots.groups = [{user_agent: "*", disallow: ["/admin/\nAllow: /"]}]
    assert_raises(Indexmap::ConfigurationError) { config.robots.body }
    config.robots.groups = [{user_agent: "*"}]
    ["/sitemap.xml", "https://user:password@example.com/sitemap.xml", "https://example.com/sitemap.xml\nDisallow: /", "file:///sitemap.xml"].each do |url|
      config.robots.sitemaps = [url]
      assert_raises(Indexmap::ConfigurationError) { config.robots.body }
    end
  end

  def test_opt_in_route_serves_get_head_and_conditional_responses_without_cookies
    Indexmap.configuration.robots.indexable = true
    Indexmap.configuration.sections = -> { raise "must not query content" }
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { get "/robots.txt", to: Indexmap::RobotsController.action(:show) }
    client = Rack::MockRequest.new(Rack::Head.new(routes))
    response = client.get("/robots.txt", "HTTP_HOST" => "attacker.example")
    assert_equal 200, response.status
    assert_match "text/plain", response["content-type"]
    assert_includes response.body, "Sitemap: https://example.com/sitemap.xml"
    assert_includes response["cache-control"], "max-age=3600"
    assert_nil response["set-cookie"]
    head = client.head("/robots.txt")
    assert_equal 200, head.status
    assert_empty head.body
    cached = client.get("/robots.txt", "HTTP_IF_NONE_MATCH" => response["etag"])
    assert_equal 304, cached.status
    assert_empty cached.body
    assert_equal 404, client.post("/robots.txt").status
    Indexmap.configuration.robots.indexable = false
    disabled = client.get("/robots.txt", "HTTP_IF_NONE_MATCH" => response["etag"])
    assert_equal 200, disabled.status
    assert_equal "User-agent: *\nDisallow: /\n", disabled.body
  end
end
