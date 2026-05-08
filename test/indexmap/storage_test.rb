# frozen_string_literal: true

require "test_helper"

class IndexmapStorageTest < Minitest::Test
  class FakeAttachment
    attr_reader :body, :content_type

    def attach(io:, filename:, content_type:)
      @filename = filename
      @body = io.read
      @content_type = content_type
    end

    def attached?
      !!@filename
    end

    def download
      body
    end

    def purge
      @filename = nil
      @body = nil
      @content_type = nil
    end
  end

  class FakeRecord
    attr_reader :file
    attr_accessor :filename

    def initialize(filename:)
      @filename = filename
      @file = FakeAttachment.new
      @persisted = false
    end

    def persisted?
      @persisted
    end

    def save!
      @persisted = true
    end
  end

  class FakeRelation
    include Enumerable

    def initialize(records)
      @records = records
    end

    def each(&block)
      @records.each(&block)
    end
  end

  class FakeModel
    def initialize
      @records = {}
    end

    def find_or_initialize_by(filename:)
      @records[filename] ||= FakeRecord.new(filename: filename)
    end

    def find_by(filename:)
      @records[filename]
    end

    def all
      FakeRelation.new(@records.values)
    end
  end

  def test_filesystem_storage_writes_reads_lists_and_builds_public_urls
    Dir.mktmpdir do |dir|
      storage = Indexmap::Storage::Filesystem.new(path: dir, public_url: "https://example.com")

      storage.write("sitemap.xml", "<xml/>")
      storage.write("robots.txt", "robots", content_type: "text/plain")

      assert storage.exist?("sitemap.xml")
      assert_equal "<xml/>", storage.read("sitemap.xml")
      assert_equal ["sitemap.xml"], storage.list(prefix: "sitemap", suffix: ".xml")
      assert_equal "https://example.com/sitemap.xml", storage.public_url("sitemap.xml")
    end
  end

  def test_filesystem_storage_rejects_absolute_filenames
    Dir.mktmpdir do |dir|
      storage = Indexmap::Storage::Filesystem.new(path: dir)

      assert_raises(ArgumentError) { storage.write("/tmp/sitemap.xml", "") }
    end
  end

  def test_active_storage_adapter_does_not_require_active_storage_to_load
    assert Indexmap::Storage::ActiveStorage
  end

  def test_active_storage_adapter_uses_supplied_model_and_attachment
    model = FakeModel.new
    storage = Indexmap::Storage::ActiveStorage.new(
      model: model,
      public_url: "https://example.com"
    )

    storage.write("sitemap.xml", "<xml/>")

    assert storage.exist?("sitemap.xml")
    assert_equal "<xml/>", storage.read("sitemap.xml")
    assert_equal ["sitemap.xml"], storage.list(prefix: "sitemap", suffix: ".xml")
    assert_equal "https://example.com/sitemap.xml", storage.public_url("sitemap.xml")
  end
end
