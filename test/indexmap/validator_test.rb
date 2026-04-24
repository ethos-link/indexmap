# frozen_string_literal: true

require "test_helper"

class IndexmapValidatorTest < Minitest::Test
  def test_validate_raises_for_missing_sitemap
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("missing.xml")

      error = assert_raises(Indexmap::ValidationError) do
        Indexmap::Validator.new(path: path).validate!
      end

      assert_equal "Missing sitemap file: #{path}", error.message
    end
  end

  def test_validate_raises_for_duplicate_urls
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("sitemap.xml")
      path.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.com/about</loc></url>
          <url><loc>https://example.com/about</loc></url>
        </urlset>
      XML

      error = assert_raises(Indexmap::ValidationError) do
        Indexmap::Validator.new(path: path).validate!
      end

      assert_equal "Duplicate sitemap URLs detected: https://example.com/about", error.message
    end
  end

  def test_validate_raises_for_parameterized_urls
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("sitemap.xml")
      path.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.com/about?ref=test</loc></url>
        </urlset>
      XML

      error = assert_raises(Indexmap::ValidationError) do
        Indexmap::Validator.new(path: path).validate!
      end

      assert_equal "Parameterized sitemap URLs detected: https://example.com/about?ref=test", error.message
    end
  end

  def test_validate_raises_for_fragment_urls
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("sitemap.xml")
      path.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.com/about#team</loc></url>
        </urlset>
      XML

      error = assert_raises(Indexmap::ValidationError) do
        Indexmap::Validator.new(path: path).validate!
      end

      assert_equal "Fragment sitemap URLs detected: https://example.com/about#team", error.message
    end
  end

  def test_validate_raises_for_relative_urls
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("sitemap.xml")
      path.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>/about</loc></url>
        </urlset>
      XML

      error = assert_raises(Indexmap::ValidationError) do
        Indexmap::Validator.new(path: path).validate!
      end

      assert_equal "Invalid sitemap URLs detected: /about", error.message
    end
  end

  def test_validate_raises_for_urls_outside_configured_base_url
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("sitemap.xml")
      path.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://other.example.com/about</loc></url>
        </urlset>
      XML

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://example.com"

      error = assert_raises(Indexmap::ValidationError) do
        Indexmap::Validator.new(configuration: configuration, path: path).validate!
      end

      assert_equal "Sitemap URLs outside configured base URL detected: https://other.example.com/about", error.message
    end
  end

  def test_validate_raises_for_invalid_lastmod_values
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("sitemap.xml")
      path.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url>
            <loc>https://example.com/about</loc>
            <lastmod>not-a-date</lastmod>
          </url>
        </urlset>
      XML

      error = assert_raises(Indexmap::ValidationError) do
        Indexmap::Validator.new(path: path).validate!
      end

      assert_equal "Invalid sitemap lastmod values detected: https://example.com/about", error.message
    end
  end

  def test_validate_raises_for_empty_sitemaps
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("sitemap.xml")
      path.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        </urlset>
      XML

      error = assert_raises(Indexmap::ValidationError) do
        Indexmap::Validator.new(path: path).validate!
      end

      assert_equal "Sitemap has no URLs: #{path}", error.message
    end
  end

  def test_validate_raises_for_missing_child_sitemap_files
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("sitemap.xml")
      child_path = Pathname(directory).join("sitemap-pages.xml")
      path.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>https://example.com/sitemap-pages.xml</loc></sitemap>
        </sitemapindex>
      XML

      error = assert_raises(Indexmap::ValidationError) do
        Indexmap::Validator.new(path: path).validate!
      end

      assert_equal "Missing child sitemap file: #{child_path}", error.message
    end
  end

  def test_validate_passes_for_valid_sitemap
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("sitemap.xml")
      path.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.com/about</loc></url>
        </urlset>
      XML

      assert Indexmap::Validator.new(path: path).validate!
    end
  end
end
