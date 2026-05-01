# frozen_string_literal: true

require "test_helper"

class IndexmapStoresFileTest < Minitest::Test
  def test_upload_writes_and_fetch_reads_artifact
    Dir.mktmpdir do |dir|
      store = Indexmap::Stores::File.new(dir)

      artifact = store.upload(
        filename: "sitemap-pages.xml",
        body: "<urlset/>",
        content_type: "application/xml"
      )

      assert_equal "sitemap-pages.xml", artifact.filename
      assert_equal "<urlset/>", store.fetch!("sitemap-pages.xml").body
      assert_equal 64, store.fetch!("sitemap-pages.xml").checksum.length
    end
  end

  def test_fetch_returns_nil_for_missing_artifact
    Dir.mktmpdir do |dir|
      store = Indexmap::Stores::File.new(dir)

      assert_nil store.fetch("missing.xml")
    end
  end
end
