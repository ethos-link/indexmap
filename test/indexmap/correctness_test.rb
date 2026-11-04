# frozen_string_literal: true

require "test_helper"

class IndexmapCorrectnessTest < Minitest::Test
  def test_resolves_only_the_selected_source_once_per_generation
    %i[index single_file].each do |format|
      calls = Hash.new(0)
      configuration = configuration_with
      configuration.format = format
      configuration.entries = -> do
        calls[:entries] += 1
        [Indexmap::Entry.new(loc: "https://example.com/page")]
      end
      configuration.sections = -> do
        calls[:sections] += 1
        [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: [{loc: "https://example.com/page"}])]
      end

      2.times { Indexmap.create(configuration: configuration) }

      assert_equal((format == :index) ? {sections: 2} : {entries: 2}, calls)
    end
  end

  def test_url_count_boundary
    body = urlset((1..50_000).map { |id| "<url><loc>https://example.com/#{id}</loc></url>" }.join)
    assert validate(body)

    error = assert_raises(Indexmap::ValidationError) do
      validate(body.sub("</urlset>", "<url><loc>https://example.com/extra</loc></url></urlset>"))
    end
    assert_match "50,000", error.message
  end

  def test_index_count_limit_precedes_child_reads
    body = index((1..50_001).map { |id| "https://example.com/sitemap-#{id}.xml" })
    error = assert_raises(Indexmap::ValidationError) { validate(body) }
    assert_match "50,000", error.message
  end

  def test_uncompressed_utf8_byte_boundary
    body = urlset("<url><loc>https://example.com/page</loc></url>")
    padding = 52_428_800 - body.bytesize
    comments = []
    while padding > 1_000_007
      comments << "<!--#{"x" * 1_000_000}-->"
      padding -= 1_000_007
    end
    comments << "<!--#{"x" * (padding - 7)}-->"
    body = body.sub("</urlset>", "#{comments.join}</urlset>")
    assert_equal 52_428_800, body.bytesize
    assert validate(body)

    error = assert_raises(Indexmap::ValidationError) { validate(body.sub("page", "pagé")) }
    assert_match "52,428,800", error.message
  end

  def test_rejects_foreign_child_origins_even_when_the_local_file_exists
    %w[https://other.example/sitemap-child.xml http://example.com/sitemap-child.xml https://example.com:444/sitemap-child.xml //other.example/sitemap-child.xml].each do |location|
      configuration = configuration_with
      configuration.storage.write("sitemap.xml", index([location]))
      configuration.storage.write("sitemap-child.xml", urlset("<url><loc>https://example.com/page</loc></url>"))

      assert_raises(Indexmap::ValidationError) { Indexmap::Validator.new(configuration: configuration).validate! }
    end
  end

  def test_rejects_self_and_multi_file_cycles
    configuration = configuration_with
    configuration.storage.write("sitemap.xml", index(["https://example.com/sitemap.xml"]))
    error = assert_raises(Indexmap::ValidationError) { Indexmap::Validator.new(configuration: configuration).validate! }
    assert_match "cycle", error.message

    configuration.storage.write("sitemap.xml", index(["https://example.com/sitemap-child.xml"]))
    configuration.storage.write("sitemap-child.xml", index(["https://example.com/sitemap.xml"]))
    assert_raises(Indexmap::ValidationError) { Indexmap::Validator.new(configuration: configuration).validate! }
  end

  def test_rejects_dtds_and_unsafe_child_paths
    assert_raises(Indexmap::ValidationError) do
      validate('<!DOCTYPE urlset [<!ENTITY example "https://example.com/page">]>' + urlset("<url><loc>&example;</loc></url>"))
    end
    %w[../outside.xml https://example.com/sitemap.xml?query=1 https://example.com/sitemap.xml#fragment].each do |location|
      assert_raises(Indexmap::ValidationError) { validate(index([location])) }
    end
  end

  def test_rejects_missing_locations_and_incorrect_namespaces
    [urlset("<url/>"), urlset("<url><loc/></url>"), index(["", "https://example.com/child.xml"]),
      '<urlset xmlns="https://other.example/schema"><url><loc>https://example.com/page</loc></url></urlset>'].each do |body|
      assert_raises(Indexmap::ValidationError) { validate(body) }
    end
    assert_raises(Indexmap::ValidationError) do
      validate(urlset("<url><loc>https://user:password@example.com/page</loc></url>"))
    end
  end

  def test_validates_deep_indexes_without_recursion_or_repeated_reads
    configuration = configuration_with
    storage = configuration.storage
    reads = Hash.new(0)
    storage.define_singleton_method(:read) do |name|
      reads[name] += 1
      super(name)
    end
    names = ["sitemap.xml", *(1..1200).map { |id| "sitemap-#{id}.xml" }]
    names.each_cons(2) { |parent, child| storage.write(parent, index(["https://example.com/#{child}"])) }
    storage.write(names.last, urlset("<url><loc>https://example.com/page</loc></url>"))

    validator = Indexmap::Validator.new(configuration: configuration)
    assert validator.validate!
    assert_equal ["https://example.com/page"], validator.entries.map(&:loc)
    assert_equal names.size, reads.size
    assert reads.values.all? { |count| count == 1 }
  end

  def test_location_length_and_repeated_fields_are_bounded
    prefix = "https://example.com/"
    location = prefix + "a" * (2047 - prefix.length)
    assert validate(urlset("<url><loc>#{location}</loc></url>"))
    assert_raises(Indexmap::ValidationError) { validate(urlset("<url><loc>#{location}x</loc></url>")) }
    assert_raises(Indexmap::ValidationError) do
      validate(urlset("<url><loc>https://example.com/</loc><loc>https://example.com/other</loc></url>"))
    end
    assert_raises(Indexmap::ValidationError) do
      validate(urlset("<url><loc>https://example.com/</loc><lastmod/><lastmod/></url>"))
    end
  end

  private

  def configuration_with
    Indexmap::Configuration.new.tap do |configuration|
      configuration.base_url = "https://example.com"
      configuration.storage = Indexmap::Storage::Memory.new
    end
  end

  def validate(body)
    configuration = configuration_with
    configuration.storage.write("sitemap.xml", body)
    Indexmap::Validator.new(configuration: configuration).validate!
  end

  def urlset(body)
    %(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">#{body}</urlset>)
  end

  def index(locations)
    %(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">#{locations.map { |loc| "<sitemap><loc>#{loc}</loc></sitemap>" }.join}</sitemapindex>)
  end
end
