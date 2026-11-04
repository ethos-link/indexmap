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

  def test_rejects_cross_origin_children_including_scheme_relative_urls
    ["https://other.example/child.xml", "//other.example/child.xml", "http://www.example.com/child.xml",
      "https://www.example.com:444/child.xml", "https://user@www.example.com/child.xml"].each do |child|
      stub_request(:get, "https://www.example.com/sitemap.xml").to_return(
        body: "<sitemapindex><sitemap><loc>#{child}</loc></sitemap></sitemapindex>"
      )
      error = assert_raises(Indexmap::ValidationError) do
        Indexmap::Parser.new(source: "https://www.example.com/sitemap.xml").entries
      end
      assert_match(/source origin/, error.message)
    end
    assert_requested :get, "https://www.example.com/sitemap.xml", times: 5
  end

  def test_redirects_are_limited_to_the_source_origin
    stub_request(:get, "https://www.example.com/sitemap.xml")
      .to_return(status: 302, headers: {"Location" => "/current.xml"})
    stub_request(:get, "https://www.example.com/current.xml")
      .to_return(body: "<urlset><url><loc>https://www.example.com/page</loc></url></urlset>")
    assert_equal ["/page"], Indexmap::Parser.new(source: "https://www.example.com/sitemap.xml").paths

    stub_request(:get, "https://www.example.com/current.xml")
      .to_return(status: 302, headers: {"Location" => "http://169.254.169.254/metadata"})
    assert_raises(Indexmap::ValidationError) do
      Indexmap::Parser.new(source: "https://www.example.com/sitemap.xml").entries
    end
    assert_not_requested :get, "http://169.254.169.254/metadata"
  end

  def test_redirect_loops_stop
    stub_request(:get, "https://www.example.com/sitemap.xml")
      .to_return(status: 302, headers: {"Location" => "/sitemap.xml"})
    assert_empty Indexmap::Parser.new(source: "https://www.example.com/sitemap.xml").entries
    assert_requested :get, "https://www.example.com/sitemap.xml", times: 4
  end

  def test_rejects_oversized_remote_responses_with_and_without_content_length
    [{}, {"Content-Length" => (Indexmap::Validator::MAX_BYTES + 1).to_s}].each do |headers|
      stub_request(:get, "https://www.example.com/sitemap.xml")
        .to_return(body: "x" * (Indexmap::Validator::MAX_BYTES + 1), headers: headers)
      assert_raises(Indexmap::ValidationError) do
        Indexmap::Parser.new(source: "https://www.example.com/sitemap.xml").entries
      end
    end
  end

  def test_rejects_oversized_redirect_and_error_bodies
    [302, 500].each do |status|
      stub_request(:get, "https://www.example.com/sitemap.xml")
        .to_return(status: status, body: "x" * (Indexmap::Validator::MAX_BYTES + 1))
      assert_raises(Indexmap::ValidationError) do
        Indexmap::Parser.new(source: "https://www.example.com/sitemap.xml").entries
      end
    end
  end

  def test_enumerates_storage_without_whole_file_reads_and_handles_cycles
    storage = Indexmap::Storage::Memory.new
    storage.write("sitemap.xml", "<sitemapindex><sitemap><loc>sitemap.xml</loc></sitemap><sitemap><loc>child.xml</loc></sitemap></sitemapindex>")
    storage.write("child.xml", "<urlset><url><loc>https://example.com/a</loc><lastmod>2026-04-21</lastmod></url><url><loc>https://example.com/b</loc></url></urlset>")
    storage.define_singleton_method(:metadata) { |name| {bytes: files.fetch(name).body.bytesize} }
    storage.define_singleton_method(:open) { |name, &block| block.call(StringIO.new(files.fetch(name).body)) }
    storage.define_singleton_method(:read) { |*| raise "whole-file read" }
    parser = Indexmap::Parser.new(storage: storage)
    entries = parser.each_entry.to_a
    assert_equal ["https://example.com/a", "https://example.com/b"], entries.map(&:loc)
    assert_equal ["2026-04-21", nil], entries.map(&:lastmod)
    refute parser.instance_variable_defined?(:@entries)
  end

  def test_rejects_dtds_without_fetching_entities
    storage = Indexmap::Storage::Memory.new
    storage.write("sitemap.xml", '<!DOCTYPE urlset [<!ENTITY x SYSTEM "http://example.com/secret">]><urlset><url><loc>&x;</loc></url></urlset>')
    assert_raises(Indexmap::ValidationError) { Indexmap::Parser.new(storage: storage).entries }
    assert_not_requested :get, "http://example.com/secret"
  end
end
