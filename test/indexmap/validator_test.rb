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
