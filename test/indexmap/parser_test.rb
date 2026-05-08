# frozen_string_literal: true

require "test_helper"

class IndexmapParserTest < Minitest::Test
  def test_parses_remote_sitemap_urlset
    stub_request(:get, "https://www.example.com/sitemap.xml")
      .to_return(
        status: 200,
        body: <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <url><loc>https://www.example.com/</loc></url>
            <url><loc>https://www.example.com/pages/features</loc></url>
          </urlset>
        XML
      )

    parser = Indexmap::Parser.new(source: "https://www.example.com/sitemap.xml")

    assert_equal ["/", "/pages/features"], parser.paths
  end

  def test_parses_remote_sitemap_index_with_child_sitemap
    stub_request(:get, "https://www.example.com/sitemap.xml")
      .to_return(
        status: 200,
        body: <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <sitemap><loc>/sitemaps/content.xml</loc></sitemap>
          </sitemapindex>
        XML
      )

    stub_request(:get, "https://www.example.com/sitemaps/content.xml")
      .to_return(
        status: 200,
        body: <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <url><loc>https://www.example.com/tools/google-reviews-calculator</loc></url>
          </urlset>
        XML
      )

    parser = Indexmap::Parser.new(source: "https://www.example.com/sitemap.xml")

    assert_equal ["/tools/google-reviews-calculator"], parser.paths
    assert_equal ["https://www.reviato.com/tools/google-reviews-calculator"], parser.urls(base_url: "https://www.reviato.com")
  end

  def test_can_rebase_remote_child_sitemap_urls_to_the_fetched_sitemap_origin
    stub_request(:get, "http://localhost:3001/sitemap.xml")
      .to_return(
        status: 200,
        body: <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <sitemap><loc>https://www.reviato.com/sitemap-marketing.xml</loc></sitemap>
          </sitemapindex>
        XML
      )

    stub_request(:get, "http://localhost:3001/sitemap-marketing.xml")
      .to_return(
        status: 200,
        body: <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <url><loc>https://www.reviato.com/pages/pricing</loc></url>
          </urlset>
        XML
      )

    parser = Indexmap::Parser.new(source: "http://localhost:3001/sitemap.xml", rebase_remote_children: true)

    assert_equal ["/pages/pricing"], parser.paths
    assert_equal ["http://localhost:3001/pages/pricing"], parser.urls(base_url: "http://localhost:3001")
  end

  def test_parses_storage_sitemap_index_with_directory_keys
    storage = Indexmap::Storage::Memory.new
    storage.write("sitemaps/sitemap.xml", <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sitemap><loc>https://www.example.com/sitemaps/content.xml</loc></sitemap>
      </sitemapindex>
    XML
    storage.write("sitemaps/content.xml", <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://www.example.com/pages/features</loc></url>
      </urlset>
    XML

    parser = Indexmap::Parser.new(source: "sitemaps/sitemap.xml", storage: storage)

    assert_equal ["/pages/features"], parser.paths
    assert_equal ["sitemaps/content.xml"], parser.entries.map(&:source_sitemap)
  end

  def test_parses_relative_child_sitemaps_from_parent_directory
    storage = Indexmap::Storage::Memory.new
    storage.write("sitemaps/sitemap.xml", <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sitemap><loc>content.xml</loc></sitemap>
      </sitemapindex>
    XML
    storage.write("sitemaps/content.xml", <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://www.example.com/pages/pricing</loc></url>
      </urlset>
    XML

    parser = Indexmap::Parser.new(source: "sitemaps/sitemap.xml", storage: storage)

    assert_equal ["/pages/pricing"], parser.paths
  end
end
