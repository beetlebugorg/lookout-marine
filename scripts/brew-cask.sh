#!/usr/bin/env bash
# Print the Homebrew cask for a released version, reading the dmg's sha256
# out of <dist-dir> (the artifacts release.yml just published). The tap job
# pipes this into Casks/lookout-marine.rb.
#
# Usage: brew-cask.sh <version> <dist-dir>
set -euo pipefail

version="$1"
dist="$2"
# The repo the release lives in, so a fork's test release yields a cask
# pointing at the fork's own downloads.
repo="${GITHUB_REPOSITORY:-beetlebugorg/lookout-marine}"

sha="$(shasum -a 256 "$dist/LookoutMarine-$version-macos-arm64.dmg" | cut -d' ' -f1)"

cat <<EOF
cask "lookout-marine" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$repo/releases/download/v#{version}/LookoutMarine-#{version}-macos-arm64.dmg"
  name "Lookout Marine"
  desc "S-57/S-101 chartplotter"
  homepage "https://github.com/$repo"

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "LookoutMarine.app"
end
EOF
