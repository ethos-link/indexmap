# frozen_string_literal: true

require "test_helper"

class IndexmapWriterTest < Minitest::Test
  def test_transcodes_input_to_utf8_before_escaping_and_partitioning
    location = "https://example.com/caf\xE9&tea".dup.force_encoding(Encoding::ISO_8859_1)
    files = Indexmap::Writer.new(base_url: "https://example.com",
      sections: [{filename: "sitemap-pages.xml", entries: [{loc: location}]}]).write

    assert_equal Encoding::UTF_8, files.first.body.encoding
    assert_includes files.first.body, "https://example.com/café&amp;tea"
    assert files.first.body.valid_encoding?
  end

  def test_rejects_invalid_input_encoding
    location = "https://example.com/\xFF".dup.force_encoding(Encoding::UTF_8)

    assert_raises(Indexmap::ValidationError) do
      Indexmap::Writer.new(base_url: "https://example.com",
        entries: [{loc: location}], format: :single_file).write
    end
  end

  def test_partitioning_counts_transcoded_and_escaped_bytes
    entries = (1..3).map do |id|
      {loc: ("https://example.com/#{id}" + "\xE9&" * 30).force_encoding(Encoding::ISO_8859_1)}
    end
    files = Indexmap::Writer.new(base_url: "https://example.com", max_bytes: 500,
      sections: [{filename: "sitemap-pages.xml", entries: entries}]).write

    assert_equal ["sitemap-pages.xml", "sitemap-pages-002.xml", "sitemap-pages-003.xml", "sitemap.xml"], files.map(&:filename)
    files.each do |file|
      assert_equal Encoding::UTF_8, file.body.encoding
      assert_operator file.body.bytesize, :<=, 500
    end
    assert_includes files.first.body, "é&amp;"
  end

  def test_default_url_limit_splits_a_lazy_source_without_losing_entries
    entries = (1..50_001).lazy.map { |id| {loc: "https://example.com/#{id}"} }
    files = Indexmap::Writer.new(base_url: "https://example.com",
      sections: [{filename: "sitemap-pages.xml", entries: entries}]).write

    assert_equal [50_000, 1], files.first(2).map { |file| file.body.scan("<url>").size }
    assert_includes files.last.body, "https://example.com/sitemap-pages-002.xml"
    assert_includes files[1].body, "https://example.com/50001"
  end

  def test_writes_sitemap_index_and_child_sitemap_documents
    sections = [
      Indexmap::Section.new(
        filename: "sitemap-pages.xml",
        entries: [
          Indexmap::Entry.new(loc: "https://example.com/", lastmod: Date.new(2026, 4, 21)),
          Indexmap::Entry.new(loc: "https://example.com/pricing", lastmod: Time.utc(2026, 4, 22, 10, 30, 0))
        ]
      )
    ]

    files = Indexmap::Writer.new(
      sections: sections,
      base_url: "https://example.com"
    ).write

    index_xml = files.find { |file| file.filename == "sitemap.xml" }.body
    child_xml = files.find { |file| file.filename == "sitemap-pages.xml" }.body

    assert_includes index_xml, "<loc>https://example.com/sitemap-pages.xml</loc>"
    assert_includes child_xml, "<loc>https://example.com/</loc>"
    assert_includes child_xml, "<loc>https://example.com/pricing</loc>"
    assert_includes child_xml, "<lastmod>2026-04-21</lastmod>"
    assert_includes child_xml, "<lastmod>2026-04-22T10:30:00Z</lastmod>"
  end

  def test_accepts_hash_based_sections_and_entries
    files = Indexmap::Writer.new(
      sections: [
        {
          filename: "sitemap-pages.xml",
          entries: [
            {loc: "https://example.com/about", lastmod: "2026-04-20T09:15:00Z"}
          ]
        }
      ],
      base_url: "https://example.com"
    ).write

    child_xml = files.find { |file| file.filename == "sitemap-pages.xml" }.body

    assert_includes child_xml, "<loc>https://example.com/about</loc>"
    assert_includes child_xml, "<lastmod>2026-04-20T09:15:00Z</lastmod>"
  end

  def test_writes_single_file_urlset
    files = Indexmap::Writer.new(
      format: :single_file,
      entries: [
        Indexmap::Entry.new(loc: "https://example.com/", lastmod: Date.new(2026, 4, 21)),
        {loc: "https://example.com/about", lastmod: "2026-04-22T09:15:00Z"}
      ],
      base_url: "https://example.com"
    ).write

    sitemap_xml = files.fetch(0).body

    assert_equal 1, files.size
    assert_equal "sitemap.xml", files.fetch(0).filename
    assert_includes sitemap_xml, "<urlset"
    assert_includes sitemap_xml, "<loc>https://example.com/</loc>"
    assert_includes sitemap_xml, "<loc>https://example.com/about</loc>"
    assert_includes sitemap_xml, "<lastmod>2026-04-21</lastmod>"
    assert_includes sitemap_xml, "<lastmod>2026-04-22T09:15:00Z</lastmod>"
    refute_includes sitemap_xml, "<sitemapindex"
  end

  def test_omits_sitemap_index_lastmod_when_sections_have_no_lastmod
    files = Indexmap::Writer.new(
      sections: [
        Indexmap::Section.new(
          filename: "sitemap-pages.xml",
          entries: [Indexmap::Entry.new(loc: "https://example.com/about")]
        )
      ],
      base_url: "https://example.com"
    ).write

    index_xml = files.find { |file| file.filename == "sitemap.xml" }.body

    refute_includes index_xml, "<lastmod>"
  end

  def test_consumes_section_entries_once_and_preserves_output_and_latest_date
    entries = [
      {loc: "https://example.com/first", lastmod: Date.new(2026, 4, 21)},
      {loc: "https://example.com/second", lastmod: "2026-04-22T09:15:00Z"},
      {loc: "https://example.com/third", lastmod: nil}
    ]
    iterations = 0
    source = Enumerator.new do |yielder|
      iterations += 1
      raise "source was enumerated twice" if iterations > 1

      entries.each { |entry| yielder << entry }
    end
    expected = Indexmap::Writer.new(base_url: "https://example.com",
      sections: [{filename: "sitemap-pages.xml", entries: entries}]).write
    actual = Indexmap::Writer.new(base_url: "https://example.com",
      sections: [{filename: "sitemap-pages.xml", entries: source}]).write

    assert_equal expected.map(&:body), actual.map(&:body)
    assert_equal 1, iterations
    assert_includes actual.last.body, "<lastmod>2026-04-22T09:15:00Z</lastmod>"
  end

  def test_create_publishes_a_one_shot_section_source
    configuration = Indexmap::Configuration.new
    configuration.base_url = "https://example.com"
    configuration.storage = Indexmap::Storage::Memory.new
    iterations = 0
    source = Enumerator.new do |yielder|
      iterations += 1
      raise "source was enumerated twice" if iterations > 1

      yielder << Indexmap::Entry.new(loc: "https://example.com/page", lastmod: Time.utc(2026, 4, 21))
    end
    configuration.sections = [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: source)]

    assert_equal ["sitemap-pages.xml", "sitemap.xml"], Indexmap.create(configuration: configuration)
    assert_equal 1, iterations
    assert_includes configuration.storage.read("sitemap.xml"), "<lastmod>2026-04-21T00:00:00Z</lastmod>"
    assert_includes configuration.storage.read("sitemap-pages.xml"), "<loc>https://example.com/page</loc>"
  end
end
