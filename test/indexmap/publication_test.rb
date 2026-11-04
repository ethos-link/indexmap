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

  def test_failed_copy_does_not_change_published_files_or_leave_staging
    Dir.mktmpdir do |directory|
      config = configuration(directory)
      Indexmap.create(configuration: config)
      storage = config.storage
      previous = storage.list.to_h { |filename| [filename, storage.read(filename)] }
      storage.define_singleton_method(:publish) do |source, **options|
        calls = 0
        source.define_singleton_method(:open) do |filename, &block|
          calls += 1
          raise IOError, "interrupted copy" if calls == 2

          super(filename, &block)
        end
        super(source, **options)
      end
      assert_raises(IOError) { Indexmap.create(configuration: config) }
      assert_equal previous, storage.list.to_h { |filename| [filename, storage.read(filename)] }
      assert_empty Dir.glob(File.join(directory, ".indexmap-builds/*/build-*"))
    end
  end

  def test_atomic_refresh_preserves_existing_root_permissions
    Dir.mktmpdir do |directory|
      config = configuration(directory)
      Indexmap.create(configuration: config)
      root = File.join(directory, "sitemap.xml")
      File.chmod(0o640, root)
      Indexmap.create(configuration: config)
      assert_equal 0o640, File.stat(root).mode & 0o777
      assert Indexmap::Validator.new(configuration: config).validate!
    end
  end

  def test_failed_root_activation_removes_new_children
    Dir.mktmpdir do |directory|
      config = configuration(directory)
      old = Indexmap.create(configuration: config)
      previous = config.storage.read("sitemap.xml")
      rename = File.method(:rename)
      File.stub(:rename, ->(source, destination) do
        raise Errno::EACCES, "root activation denied" if destination.to_s == File.join(directory, "sitemap.xml")

        rename.call(source, destination)
      end) do
        assert_raises(Errno::EACCES) { Indexmap.create(configuration: config) }
      end
      assert_equal previous, config.storage.read("sitemap.xml")
      children = config.storage.list(prefix: "sitemap-", suffix: ".xml").reject { |name| name.end_with?("-index.xml") }
      assert_equal (old - ["sitemap.xml"]).sort, children
      assert_empty Dir.glob(File.join(directory, ".indexmap-builds/*/build-*"))
      assert Indexmap::Validator.new(configuration: config).validate!
    end
  end

  def test_copying_does_not_block_a_competing_publisher
    Dir.mktmpdir do |directory|
      config = configuration(directory)
      Indexmap.create(configuration: config)
      storage = config.storage
      entered = Queue.new
      release = Queue.new
      storage.define_singleton_method(:publish) do |source, **options|
        source.define_singleton_method(:open) do |filename, &block|
          unless @paused
            @paused = true
            entered << true
            release.pop
          end
          super(filename, &block)
        end
        super(source, **options)
      end
      thread = Thread.new do
        Indexmap.create(configuration: config)
      rescue Indexmap::SupersededPublication => error
        error
      end
      Timeout.timeout(5) { entered.pop }
      competing = configuration(directory)
      winner = Timeout.timeout(5) { Indexmap.create(configuration: competing) }
      release << true
      assert_instance_of Indexmap::SupersededPublication, Timeout.timeout(5) { thread.value }
      assert winner.all? { |filename| storage.exist?(filename) }
      assert Indexmap::Parser.new(storage: storage).entries.all? { |entry| winner.include?(entry.source_sitemap) }
      assert Indexmap::Validator.new(configuration: config).validate!
      assert_empty Dir.glob(File.join(directory, ".indexmap-builds/*/build-*"))
    ensure
      thread&.kill if thread&.alive?
    end
  end

  def test_pruning_reclaims_crashed_staging_and_skips_live_builds
    Dir.mktmpdir do |directory|
      config = configuration(directory)
      Indexmap.create(configuration: config)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        config.storage.define_singleton_method(:publish) do |source, **options|
          source.define_singleton_method(:open) do |filename, &block|
            writer.write("staging")
            writer.flush
            sleep
            super(filename, &block)
          end
          super(source, **options)
        end
        Indexmap.create(configuration: config)
      end
      writer.close
      assert IO.select([reader], nil, nil, 5), "build did not reach destination staging"
      reader.read(7)
      staged = Dir.glob(File.join(directory, ".indexmap-builds/*/build-*")).fetch(0)
      File.utime(Time.at(0), Time.at(0), staged)
      assert_empty config.storage.prune(root: "sitemap.xml", before: Time.now.utc - 3600)
      assert File.directory?(staged)
      Process.kill("KILL", pid)
      Process.wait(pid)
      pid = nil
      deleted = config.storage.prune(root: "sitemap.xml", before: Time.now.utc - 3600)
      assert_equal [Pathname(staged).relative_path_from(Pathname(directory)).to_s], deleted
      refute File.exist?(staged)
      assert Indexmap::Validator.new(configuration: config).validate!
    ensure
      if pid
        Process.kill("KILL", pid)
        Process.wait(pid)
      end
      reader&.close
      writer&.close unless writer&.closed?
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
