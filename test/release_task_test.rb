# frozen_string_literal: true

require "test_helper"
require "rake"
require "open3"
require "rbconfig"

unless respond_to?(:release_version, true)
  load File.expand_path("../Rakefile", __dir__)
end

class ReleaseTaskTest < Minitest::Test
  def test_release_version_increments_patch_from_current_version
    major, minor, patch = Indexmap::VERSION.split(".").map(&:to_i)

    assert_equal "#{major}.#{minor}.#{patch + 1}", release_version("patch")
  end

  def test_release_version_accepts_explicit_semantic_version
    assert_equal "0.3.0", release_version("0.3.0")
  end

  def test_validate_release_version_rejects_current_version
    error = assert_raises(ArgumentError) do
      validate_release_version!("0.2.7", "0.2.7")
    end

    assert_equal(
      "Release version 0.2.7 must be newer than current version 0.2.7.",
      error.message
    )
  end

  def test_validate_release_version_rejects_existing_local_tag
    @local_release_tag_exists = true
    @remote_release_tag_exists = false

    error = assert_raises(ArgumentError) do
      validate_release_version!("0.2.8", "0.2.7")
    end

    assert_equal "Release tag v0.2.8 already exists locally.", error.message
  end

  def test_validate_release_version_rejects_existing_remote_tag
    @local_release_tag_exists = false
    @remote_release_tag_exists = true

    error = assert_raises(ArgumentError) do
      validate_release_version!("0.2.8", "0.2.7")
    end

    assert_equal "Release tag v0.2.8 already exists on origin.", error.message
  end

  def test_remote_release_tag_command_asks_git_to_fail_when_no_tag_matches
    assert_equal(
      "git ls-remote --exit-code --tags origin refs/tags/v0.2.8",
      remote_release_tag_command("v0.2.8")
    )
  end

  def test_changelog_command_prepends_the_next_release
    assert_equal(
      [
        "git-cliff",
        "-c",
        "cliff.toml",
        "--unreleased",
        "--tag",
        "v0.2.8",
        "--prepend",
        "CHANGELOG.md"
      ],
      changelog_command("0.2.8")
    )
  end

  def test_release_preparation_rejects_protected_and_detached_branches
    ["main", "master", ""].each do |branch|
      error = assert_raises(ArgumentError) { validate_release_branch!(branch) }
      assert_match(/topic branch/, error.message)
    end
    assert_nil validate_release_branch!("release/0.9.0")
  end

  def test_prepare_updates_files_without_committing_tagging_or_pushing
    script = <<~RUBY
      require "rake"
      load "Rakefile"
      def current_branch = "release/next"
      def clean_worktree? = true
      def validate_release_version!(*); end
      def update_changelog(version) = puts("changelog:" + version)
      def update_version_file(version) = puts("version:" + version)
      def sh(*) = abort("unexpected shell mutation")
      Rake::Task["release:prepare"].invoke("minor")
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script)
    assert status.success?, stderr
    expected = release_version("minor")
    assert_includes stdout, "changelog:#{expected}"
    assert_includes stdout, "version:#{expected}"
    assert_includes stdout, "release:tag"
  end

  def test_tag_pushes_only_the_prepared_merged_commit
    with_release_repository do |repo, origin|
      before = git!(repo, "rev-parse", "HEAD").strip
      stdout, stderr, status = run_release_task(repo, "release:tag")
      assert status.success?, stdout + stderr
      assert_equal before, git!(repo, "rev-parse", "HEAD").strip
      assert_equal before, git!(repo, "rev-parse", "v#{Indexmap::VERSION}^{}").strip
      assert_includes git!(origin, "tag", "--list"), "v#{Indexmap::VERSION}"
      assert_empty git!(repo, "status", "--porcelain")
    end
  end

  def test_tag_rejects_main_that_has_not_been_merged_to_origin
    with_release_repository do |repo, origin|
      File.write(File.join(repo, "unmerged.txt"), "unmerged")
      git!(repo, "add", "unmerged.txt")
      git!(repo, "commit", "-m", "test: unmerged change")
      stdout, stderr, status = run_release_task(repo, "release:tag")
      refute status.success?, stdout + stderr
      assert_includes stderr, "Local main must match origin/main"
      assert_empty git!(repo, "tag", "--list")
      assert_empty git!(origin, "tag", "--list")
    end
  end

  private

  def with_release_repository
    Dir.mktmpdir("indexmap-release-test") do |directory|
      repo = File.join(directory, "repo")
      origin = File.join(directory, "origin.git")
      FileUtils.mkdir_p([repo, origin, File.join(repo, "lib/indexmap")])
      git!(origin, "init", "--bare")
      git!(repo, "init", "-b", "main")
      git!(repo, "config", "user.name", "Release Test")
      git!(repo, "config", "user.email", "release@example.test")
      %w[Rakefile indexmap.gemspec CHANGELOG.md lib/indexmap/version.rb].each do |file|
        FileUtils.cp(File.expand_path("../#{file}", __dir__), File.join(repo, file))
      end
      git!(repo, "add", ".")
      git!(repo, "commit", "-m", "test: prepare release fixture")
      git!(repo, "remote", "add", "origin", origin)
      git!(repo, "push", "-u", "origin", "main")
      yield repo, origin
    end
  end

  def git!(directory, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: directory)
    raise stderr unless status.success?

    stdout
  end

  def run_release_task(directory, task)
    Open3.capture3(
      {"BUNDLE_GEMFILE" => File.expand_path(ENV.fetch("BUNDLE_GEMFILE", "Gemfile"))},
      RbConfig.ruby, "-rrake", "-e", 'load "Rakefile"; Rake::Task[ARGV.fetch(0)].invoke', task,
      chdir: directory
    )
  end

  def local_release_tag_exists?(_tag)
    @local_release_tag_exists || false
  end

  def remote_release_tag_exists?(_tag)
    @remote_release_tag_exists || false
  end
end
