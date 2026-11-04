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

  def test_release_preparation_requires_main
    ["release/0.9.0", "master", ""].each do |branch|
      error = assert_raises(ArgumentError) { validate_release_branch!(branch) }
      assert_match(/Prepare releases from main/, error.message)
    end
    assert_nil validate_release_branch!("main")
  end

  def test_prepare_commits_and_pushes_from_main_with_release_hook_exception
    with_release_repository do |repo, origin|
      before = git!(repo, "rev-parse", "HEAD").strip
      history = File.read(File.join(repo, "CHANGELOG.md"))
      hook = File.join(repo, ".git/hooks/pre-commit")
      File.write(hook, "#!/bin/sh\nexec ruby script/check_commit_branch.rb\n")
      FileUtils.chmod(0o755, hook)

      stdout, stderr, status = run_release_task(repo, "release:prepare[minor]")
      assert status.success?, stdout + stderr
      expected = release_version("minor")
      refute_equal before, git!(repo, "rev-parse", "HEAD").strip
      assert_equal git!(repo, "rev-parse", "HEAD"), git!(origin, "rev-parse", "main")
      assert_equal "CHANGELOG.md\nlib/indexmap/version.rb\n",
        git!(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD")
      assert_includes File.read(File.join(repo, "lib/indexmap/version.rb")), expected
      assert_includes File.read(File.join(repo, "CHANGELOG.md")), "## [#{expected}]"
      assert File.read(File.join(repo, "CHANGELOG.md")).end_with?(history[history.index("## [")..])
      message = git!(repo, "log", "-1", "--format=%B")
      assert_includes message, "chore(release): prepare v#{expected}"
      %w[What: Why: Where:].each { |heading| assert_includes message, heading }
      assert_empty git!(repo, "status", "--porcelain")
      assert_empty git!(repo, "tag", "--list")
      assert_empty git!(origin, "tag", "--list")
      assert_includes stdout, "release:tag"

      stdout, stderr, status = run_release_task(repo, "release:tag")
      assert status.success?, stdout + stderr
      assert_equal git!(repo, "rev-parse", "HEAD"), git!(origin, "rev-parse", "v#{expected}^{}")
    end
  end

  def test_prepare_keeps_commit_hooks_enabled_and_does_not_push_when_they_fail
    with_release_repository do |repo, origin|
      before = git!(origin, "rev-parse", "main")
      hook = File.join(repo, ".git/hooks/commit-msg")
      File.write(hook, "#!/bin/sh\necho 'commit hook rejected release' >&2\nexit 1\n")
      FileUtils.chmod(0o755, hook)

      stdout, stderr, status = run_release_task(repo, "release:prepare[minor]")
      refute status.success?, stdout + stderr
      assert_includes stderr, "commit hook rejected release"
      assert_equal before, git!(repo, "rev-parse", "HEAD")
      assert_equal before, git!(origin, "rev-parse", "main")
      assert_empty git!(origin, "tag", "--list")
    end
  end

  def test_branch_hook_rejects_ordinary_main_commits_even_with_release_flag
    with_release_repository do |repo, _origin|
      File.write(File.join(repo, "unrelated.txt"), "unrelated")
      git!(repo, "add", "unrelated.txt")
      [nil, "1"].each do |flag|
        _stdout, stderr, status = Open3.capture3(
          {"INDEXMAP_RELEASE_COMMIT" => flag},
          RbConfig.ruby, "script/check_commit_branch.rb", chdir: repo
        )
        refute status.success?
        assert_includes stderr, "Direct commits to 'main' are not allowed"
      end
    end
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

  def test_prepare_rejects_topic_and_detached_branches_without_changing_files
    with_release_repository do |repo, origin|
      before = git!(repo, "rev-parse", "HEAD").strip
      git!(repo, "checkout", "-b", "release/next")
      ["release/next", before].each do |ref|
        git!(repo, "checkout", ref)
        stdout, stderr, status = run_release_task(repo, "release:prepare[minor]")
        refute status.success?, stdout + stderr
        assert_includes stderr, "Prepare releases from main"
        assert_equal before, git!(repo, "rev-parse", "HEAD").strip
        assert_empty git!(repo, "status", "--porcelain")
        assert_empty git!(origin, "tag", "--list")
      end
    end
  end

  def test_tag_rejects_main_that_has_not_been_merged_to_origin
    with_release_repository do |repo, origin|
      File.write(File.join(repo, "unmerged.txt"), "unmerged")
      git!(repo, "add", "unmerged.txt")
      git!(repo, "commit", "-m", "test: unmerged change")
      %w[release:prepare[minor] release:tag].each do |task|
        stdout, stderr, status = run_release_task(repo, task)
        refute status.success?, stdout + stderr
        assert_includes stderr, "Local main must match origin/main"
        assert_empty git!(repo, "status", "--porcelain")
      end
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
      %w[Rakefile indexmap.gemspec CHANGELOG.md cliff.toml lib/indexmap/version.rb script/check_commit_branch.rb].each do |file|
        FileUtils.mkdir_p(File.dirname(File.join(repo, file)))
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
      RbConfig.ruby, "-rrake", "-e", 'load "Rakefile"; Rake.application.invoke_task(ARGV.fetch(0))', task,
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
