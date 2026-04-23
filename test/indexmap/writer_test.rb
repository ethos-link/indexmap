# frozen_string_literal: true

require "test_helper"

class IndexmapWriterTest < Minitest::Test
  def test_writes_sitemap_index_and_child_sitemap
    Dir.mktmpdir do |directory|
      sections = [
        Indexmap::Section.new(
          filename: "sitemap-pages.xml",
          entries: [
            Indexmap::Entry.new(loc: "https://example.com/", lastmod: Date.new(2026, 4, 21)),
            Indexmap::Entry.new(loc: "https://example.com/pricing", lastmod: Time.utc(2026, 4, 22, 10, 30, 0))
          ]
        )
      ]

      Indexmap::Writer.new(
        sections: sections,
        public_path: directory,
        base_url: "https://example.com"
      ).write

      index_xml = File.read(File.join(directory, "sitemap.xml"))
      child_xml = File.read(File.join(directory, "sitemap-pages.xml"))

      assert_includes index_xml, "<loc>https://example.com/sitemap-pages.xml</loc>"
      assert_includes child_xml, "<loc>https://example.com/</loc>"
      assert_includes child_xml, "<loc>https://example.com/pricing</loc>"
      assert_includes child_xml, "<lastmod>2026-04-21</lastmod>"
      assert_includes child_xml, "<lastmod>2026-04-22T10:30:00Z</lastmod>"
    end
  end

  def test_accepts_hash_based_sections_and_entries
    Dir.mktmpdir do |directory|
      Indexmap::Writer.new(
        sections: [
          {
            filename: "sitemap-pages.xml",
            entries: [
              {loc: "https://example.com/about", lastmod: "2026-04-20T09:15:00Z"}
            ]
          }
        ],
        public_path: directory,
        base_url: "https://example.com"
      ).write

      child_xml = File.read(File.join(directory, "sitemap-pages.xml"))

      assert_includes child_xml, "<loc>https://example.com/about</loc>"
      assert_includes child_xml, "<lastmod>2026-04-20T09:15:00Z</lastmod>"
    end
  end

  def test_writes_single_file_urlset
    Dir.mktmpdir do |directory|
      Indexmap::Writer.new(
        format: :single_file,
        entries: [
          Indexmap::Entry.new(loc: "https://example.com/", lastmod: Date.new(2026, 4, 21)),
          {loc: "https://example.com/about", lastmod: "2026-04-22T09:15:00Z"}
        ],
        public_path: directory,
        base_url: "https://example.com"
      ).write

      sitemap_xml = File.read(File.join(directory, "sitemap.xml"))

      assert_includes sitemap_xml, "<urlset"
      assert_includes sitemap_xml, "<loc>https://example.com/</loc>"
      assert_includes sitemap_xml, "<loc>https://example.com/about</loc>"
      assert_includes sitemap_xml, "<lastmod>2026-04-21</lastmod>"
      assert_includes sitemap_xml, "<lastmod>2026-04-22T09:15:00Z</lastmod>"
      refute_includes sitemap_xml, "<sitemapindex"
      refute File.exist?(File.join(directory, "sitemap-pages.xml"))
    end
  end

  def test_omits_sitemap_index_lastmod_when_sections_have_no_lastmod
    Dir.mktmpdir do |directory|
      Indexmap::Writer.new(
        sections: [
          Indexmap::Section.new(
            filename: "sitemap-pages.xml",
            entries: [Indexmap::Entry.new(loc: "https://example.com/about")]
          )
        ],
        public_path: directory,
        base_url: "https://example.com"
      ).write

      index_xml = File.read(File.join(directory, "sitemap.xml"))

      refute_includes index_xml, "<lastmod>"
    end
  end
end
