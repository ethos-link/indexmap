# frozen_string_literal: true

require "test_helper"
require "timeout"

class IndexmapPublicationTest < Minitest::Test
  def configuration(directory, atomic: true)
    Indexmap::Configuration.new.tap do |config|
      config.base_url = "https://example.com"
      config.storage = Indexmap::Storage::Filesystem.new(path: directory, public_url: config.base_url)
      config.atomic = atomic
      config.max_urls = 2
      config.sections = -> do
        entries = (1..5).lazy.map { |id| Indexmap::Entry.new(loc: "https://example.com/#{id}") }
        [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: entries)]
      end
    end
  end

  def test_partitions_once_and_publishes_immutable_children
    Dir.mktmpdir do |directory|
      config = configuration(directory)
      result = Indexmap::TaskRunner.new(configuration: config).create
      assert_equal [2, 2, 1, 3], result.fetch(:sitemaps).map { |file| file.fetch(:link_count) }
      old_files = result.fetch(:files)
      bodies = old_files.to_h { |file| [file, config.storage.read(file)] }
      assert_raises(Indexmap::ConfigurationError) { config.storage.write(old_files.first, "overwrite") }
      assert_raises(Indexmap::ConfigurationError) { Indexmap::TaskRunner.new(configuration: config).format }
      second = Indexmap::TaskRunner.new(configuration: config).create
      refute_equal old_files, second.fetch(:files)
      old_files.reject { |file| file == "sitemap.xml" }.each { |file| assert_equal bodies[file], config.storage.read(file) }
      publication = Indexmap::Publication.new(root: "sitemap.xml")
      assert config.storage.exist?(publication.archive(publication.generation(old_files.first)))
      assert Indexmap::Validator.new(configuration: config).validate!
    end
  end

  def test_byte_partitioning_counts_escaped_output
    Dir.mktmpdir do |directory|
      config = configuration(directory, atomic: false)
      config.max_urls = 50_000
      config.max_bytes = 400
      config.sections = [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: (1..3).map do |id|
        Indexmap::Entry.new(loc: "https://example.com/#{id}#{"a" * 100}&b")
      end)]
      files = Indexmap.create(configuration: config)
      assert_operator files.size, :>, 2
      files.each { |file| assert_operator config.storage.metadata(file).fetch(:bytes), :<=, 400 }
    end
  end

  def test_failed_upload_does_not_change_root_and_orphans_can_be_pruned
    Dir.mktmpdir do |directory|
      config = configuration(directory)
      Indexmap.create(configuration: config)
      previous = config.storage.read("sitemap.xml")
      storage = config.storage
      calls = 0
      storage.define_singleton_method(:write_io) do |filename, io, **options|
        calls += 1
        raise IOError, "interrupted upload" if calls == 2

        super(filename, io, **options)
      end
      assert_raises(IOError) { Indexmap.create(configuration: config) }
      assert_equal previous, config.storage.read("sitemap.xml")
      storage.singleton_class.remove_method(:write_io)
      config.storage.list(prefix: "sitemap-", suffix: ".xml").each do |filename|
        File.utime(Time.at(0), Time.at(0), File.join(directory, filename))
      end
      deleted = config.storage.prune(root: "sitemap.xml", before: Time.now.utc - 3600)
      assert_equal 1, deleted.size
      assert Indexmap::Validator.new(configuration: config).validate!
    end
  end

  def test_rejects_stale_builds_and_keeps_other_outputs_during_cleanup
    Dir.mktmpdir do |directory|
      config = configuration(directory)
      old = Indexmap.create(configuration: config)
      config.output(:other) do |output|
        output.index_filename = "other.xml"
        output.sections = -> { [Indexmap::Section.new(filename: "sitemap-other.xml", entries: [{loc: "https://example.com/other"}])] }
      end
      other = Indexmap.create(:other, configuration: config)
      expected = config.storage.revision("sitemap.xml")
      Indexmap.create(configuration: config)
      assert_raises(Indexmap::SupersededPublication) do
        config.storage.publish(nil, files: [], root: "sitemap.xml", expected: expected)
      end
      config.storage.list(suffix: ".xml").each { |name| File.utime(Time.at(0), Time.at(0), File.join(directory, name)) }
      deleted = config.storage.prune(root: "sitemap.xml", before: Time.now.utc - 3600)
      assert (old - ["sitemap.xml"]).all? { |file| deleted.include?(file) }
      assert other.all? { |file| config.storage.exist?(file) }
    end
  end

  def test_duplicates_across_partitions_fail_before_publication
    Dir.mktmpdir do |directory|
      config = configuration(directory)
      Indexmap.create(configuration: config)
      previous = config.storage.read("sitemap.xml")
      config.sections = [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: [
        {loc: "https://example.com/a"}, {loc: "https://example.com/b"}, {loc: "https://example.com/a"}
      ])]
      assert_raises(Indexmap::ValidationError) { Indexmap.create(configuration: config) }
      assert_equal previous, config.storage.read("sitemap.xml")
    end
  end

  def test_filesystem_rejects_symlinks_escaping_storage
    Dir.mktmpdir do |directory|
      Dir.mktmpdir do |outside|
        storage = Indexmap::Storage::Filesystem.new(path: directory)
        File.symlink(outside, File.join(directory, "escape"))
        assert_raises(ArgumentError) { storage.write("escape/private.xml", "private") }
      end
    end
  end

  def test_concurrent_builds_cannot_overwrite_a_newer_root
    Dir.mktmpdir do |directory|
      config = configuration(directory)
      entered = Queue.new
      release = Queue.new
      config.sections = -> do
        source = Enumerator.new do |stream|
          entered << true
          release.pop
          stream << Indexmap::Entry.new(loc: "https://example.com/page")
        end
        [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: source)]
      end
      threads = 2.times.map do
        Thread.new do
          Indexmap.create(configuration: config)
        rescue Indexmap::SupersededPublication => error
          error
        end
      end
      Timeout.timeout(5) { 2.times { entered.pop } }
      2.times { release << true }
      results = Timeout.timeout(5) { threads.map(&:value) }
      assert_equal 1, results.count { |result| result.is_a?(Indexmap::SupersededPublication) }
      assert Indexmap::Validator.new(configuration: config).validate!
    ensure
      threads&.each { |thread| thread.kill if thread.alive? }
    end
  end

  def test_atomic_mode_requires_an_explicit_adapter_capability
    config = Indexmap::Configuration.new
    config.atomic = true
    config.storage = Indexmap::Storage::Memory.new
    config.sections = -> { raise "must not evaluate an unsupported build" }
    assert_raises(Indexmap::ConfigurationError) { Indexmap.create(configuration: config) }
  end

  def test_duplicates_across_sort_runs_fail_before_publication
    Dir.mktmpdir do |directory|
      config = configuration(directory)
      Indexmap.create(configuration: config)
      previous = config.storage.read("sitemap.xml")
      config.max_urls = 5000
      entries = (0..10_000).lazy.map { |id| {loc: "https://example.com/#{id % 10_000}"} }
      config.sections = [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: entries)]
      assert_raises(Indexmap::ValidationError) { Indexmap.create(configuration: config) }
      assert_equal previous, config.storage.read("sitemap.xml")
    end
  end
end
