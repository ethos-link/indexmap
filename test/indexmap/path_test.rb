# frozen_string_literal: true

require "test_helper"

class IndexmapPathTest < Minitest::Test
  def test_existing_public_path_prefers_sitemap_index_when_present
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      public_path.join("sitemap_index.xml").write("<urlset/>")
      public_path.join("sitemap.xml").write("<sitemapindex/>")

      assert_equal public_path.join("sitemap.xml"), Indexmap::Path.existing_public_path(public_path: public_path)
    end
  end

  def test_existing_public_path_falls_back_to_legacy_sitemap_path
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      public_path.join("sitemap_index.xml").write("<sitemapindex/>")

      assert_equal public_path.join("sitemap_index.xml"), Indexmap::Path.existing_public_path(public_path: public_path)
    end
  end

  def test_canonical_url_targets_sitemap_index
    assert_equal "https://www.example.com/sitemap.xml", Indexmap::Path.canonical_url("https://www.example.com")
  end
end
