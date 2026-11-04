# frozen_string_literal: true

require "open3"

def git_output(*args)
  output, status = Open3.capture2("git", *args)
  abort "Could not inspect Git state." unless status.success?
  output
end

branch = git_output("branch", "--show-current").strip
exit 0 unless %w[main master].include?(branch)

if branch == "main" && ENV["INDEXMAP_RELEASE_COMMIT"] == "1"
  paths = git_output("diff", "--cached", "--name-only", "-z").split("\0").sort
  if paths == %w[CHANGELOG.md lib/indexmap/version.rb]
    version_file = git_output("show", ":lib/indexmap/version.rb")
    previous_file = git_output("show", "HEAD:lib/indexmap/version.rb")
    version = version_file[/VERSION = "(\d+\.\d+\.\d+)"/, 1]
    previous = previous_file[/VERSION = "(\d+\.\d+\.\d+)"/, 1]
    changelog = git_output("show", ":CHANGELOG.md")
    if version && previous && Gem::Version.new(version) > Gem::Version.new(previous) &&
        changelog.match?(/^## \[#{Regexp.escape(version)}\]/)
      exit 0
    end
  end
end

abort "Direct commits to '#{branch}' are not allowed. Use a feature branch or release:prepare."
