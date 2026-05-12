# frozen_string_literal: true

require "test_helper"
require "rake"

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

  private

  def local_release_tag_exists?(_tag)
    @local_release_tag_exists || false
  end

  def remote_release_tag_exists?(_tag)
    @remote_release_tag_exists || false
  end
end
