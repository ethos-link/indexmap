# frozen_string_literal: true

require "test_helper"

class IndexmapValidatorTest < Minitest::Test
  def test_validate_raises_for_missing_sitemap
    error = assert_raises(Indexmap::ValidationError) do
      Indexmap::Validator.new(configuration: configuration_with).validate!
    end

    assert_equal "Missing sitemap file: sitemap.xml", error.message
  end

  def test_validate_raises_for_duplicate_urls
    error = assert_raises(Indexmap::ValidationError) do
      validate_sitemap(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.com/about</loc></url>
          <url><loc>https://example.com/about</loc></url>
        </urlset>
      XML
    end

    assert_equal "Duplicate sitemap URLs detected: https://example.com/about", error.message
  end

  def test_validate_raises_for_parameterized_urls
    error = assert_raises(Indexmap::ValidationError) do
      validate_sitemap(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.com/about?ref=test</loc></url>
        </urlset>
      XML
    end

    assert_equal "Parameterized sitemap URLs detected: https://example.com/about?ref=test", error.message
  end

  def test_validate_raises_for_fragment_urls
    error = assert_raises(Indexmap::ValidationError) do
      validate_sitemap(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.com/about#team</loc></url>
        </urlset>
      XML
    end

    assert_equal "Fragment sitemap URLs detected: https://example.com/about#team", error.message
  end

  def test_validate_raises_for_relative_urls
    error = assert_raises(Indexmap::ValidationError) do
      validate_sitemap(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>/about</loc></url>
        </urlset>
      XML
    end

    assert_equal "Invalid sitemap URLs detected: /about", error.message
  end

  def test_validate_raises_for_urls_outside_configured_base_url
    error = assert_raises(Indexmap::ValidationError) do
      validate_sitemap(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://other.example.com/about</loc></url>
        </urlset>
      XML
    end

    assert_equal "Sitemap URLs outside configured base URL detected: https://other.example.com/about", error.message
  end

  def test_validate_raises_for_invalid_lastmod_values
    error = assert_raises(Indexmap::ValidationError) do
      validate_sitemap(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url>
            <loc>https://example.com/about</loc>
            <lastmod>not-a-date</lastmod>
          </url>
        </urlset>
      XML
    end

    assert_equal "Invalid sitemap lastmod values detected: https://example.com/about", error.message
  end

  def test_validate_raises_for_empty_sitemaps
    error = assert_raises(Indexmap::ValidationError) do
      validate_sitemap(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        </urlset>
      XML
    end

    assert_equal "Sitemap has no URLs: sitemap.xml", error.message
  end

  def test_validate_raises_for_missing_child_sitemap_files
    error = assert_raises(Indexmap::ValidationError) do
      validate_sitemap(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>https://example.com/sitemap-pages.xml</loc></sitemap>
        </sitemapindex>
      XML
    end

    assert_equal "Missing child sitemap file: sitemap-pages.xml", error.message
  end

  def test_validate_passes_for_valid_sitemap
    assert validate_sitemap(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://example.com/about</loc></url>
      </urlset>
    XML
  end

  private

  def validate_sitemap(body)
    storage = Indexmap::Storage::Memory.new
    storage.write("sitemap.xml", body)

    Indexmap::Validator.new(configuration: configuration_with(storage: storage)).validate!
  end

  def configuration_with(storage: Indexmap::Storage::Memory.new)
    Indexmap::Configuration.new.tap do |configuration|
      configuration.base_url = "https://example.com"
      configuration.storage = storage
    end
  end
end
