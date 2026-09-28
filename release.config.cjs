// semantic-release pipeline for the tweak.
//
// Conventional commits on main decide the version:
//   feat:    -> minor
//   fix:     -> patch
//   BREAKING CHANGE: / feat! -> major
// During "prepare" the Theos control file is bumped and the rootless package is
// built, so the GitHub release published in the same run carries the .deb.

const conventionalPreset = { preset: 'conventionalcommits' };

module.exports = {
  branches: ['main'],
  tagFormat: 'v${version}',
  plugins: [
    ['@semantic-release/commit-analyzer', conventionalPreset],
    [
      '@semantic-release/release-notes-generator',
      {
        preset: 'conventionalcommits',
        presetConfig: {
          types: [
            { type: 'feat', section: 'Features' },
            { type: 'fix', section: 'Bug fixes' },
            { type: 'perf', section: 'Performance' },
            { type: 'refactor', section: 'Refactoring' },
            { type: 'docs', hidden: true },
            { type: 'ci', hidden: true },
            { type: 'build', hidden: true },
            { type: 'chore', hidden: true },
          ],
        },
      },
    ],
    [
      '@semantic-release/changelog',
      {
        changelogFile: 'CHANGELOG.md',
        changelogTitle: '# Changelog\n\nAll notable changes to this tweak are documented here.\nThe format is based on [Conventional Commits](https://www.conventionalcommits.org/).',
      },
    ],
    [
      '@semantic-release/exec',
      {
        // Bumps control + builds packages/*.deb before the release is published
        prepareCmd: 'bash scripts/prepare-release.sh ${nextRelease.version}',
      },
    ],
    [
      '@semantic-release/git',
      {
        assets: ['CHANGELOG.md', 'control'],
        message: 'chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}',
      },
    ],
    [
      '@semantic-release/github',
      {
        assets: [
          {
            path: 'packages/*.deb',
            label: 'Disable Assistants ${nextRelease.version} (.deb)',
          },
        ],
        successComment: false,
      },
    ],
  ],
};
