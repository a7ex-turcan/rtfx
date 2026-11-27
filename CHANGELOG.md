# Changelog

All notable changes to rtfx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The MCP server (`rtfx.exe`) and the runner's scripts carry one version and are released together.
A release is cut by pushing a tag `v<version>`; its notes on GitHub are this file's section for that
version, so write the section before tagging.

## [Unreleased]

## [0.3.1] - 2026-11-27

The first tagged release, and the first under the MIT license.

### Added

- Private NuGet feeds. For every source in the repository's `Nuget.config` whose host matches
  `feedHosts` (`*.jfrog.io` by default), the worker hands NuGet the feed user and password the
  runner's environment holds in `JF_USER` and `JF_PASS` (`feedUserVar`, `feedPassVar`), as
  `NuGetPackageSourceCredentials_<source name>`. They exist in the job's process environment only:
  the values are never written or logged, and `result.json` names the sources under `feedSources`.
- A near-cap flag. A job that spent nine tenths or more of its credit cap gets `nearCreditCap` in
  `result.json`, `status.json` and `index.json`, and a warning. Past that point Copilot makes the
  next model call the last and takes the tools away, so the work may have been cut short even
  though the job ended as `done`. The `wait`, `status` and `result` tools pass the flag through.
- Read jobs are told to run commands plainly. A command that redirects output (`2>&1`, `> file`)
  needs an approval nobody is there to give, and was being refused.
- The janitor removes a job folder that never got a `status.json` once it is a day old.
- The server reads an optional `config.json` next to `rtfx.exe` (`remoteHost`, `remoteRoot`,
  `localRepos`, `cache`, `defaultModel`). Environment variables still win.
- GitHub Actions: a build, the unit tests and the smoke test on every push and pull request to
  `main`, and a release on every `v*` tag, with notes taken from this file.
- `build/version.ps1`, `build/release-notes.ps1` and `build/package.ps1`, which the workflows run
  and which run the same way on a desk.

### Changed

- `delegate` and `fan_out` submit a batch in two copies in total, where each job used to take two
  of its own. Every copy is a new ssh connection, so 21 jobs took four and a half minutes to queue;
  three now take about twelve seconds, and the count barely matters.
- The built-in defaults name no real machine: the host is `rtfx-worker`, the runner's root
  `C:/rtfx`, and both sides look for checkouts in `%USERPROFILE%\source\repos`. Set your own in
  the environment or in `config.json`.
- The server carries the runner's version. It reported 0.3.0 while the runner was at 0.3.1.
- The README has a getting started guide, every setting with its default, and troubleshooting.

### Fixed

- When the runner is down, the hint on how to start it names the configured root (`RTFX_ROOT`)
  instead of one fixed folder.

## [0.3.0] - 2026-11-27

### Added

- The MCP server (`rtfx mcp`, .NET 10), with eleven tools over stdio: `delegate`, `fan_out`, `wait`,
  `status`, `logs`, `result`, `diff`, `fetch`, `abort`, `discard` and `models`. Tool calls run side
  by side, so a long `wait` does not hold up a `status` or an `abort`.
- A job is not queued while the runner's heartbeat is stale, and a machine that does not answer over
  ssh is reported as such.
- Jobs no longer see the repository's skills, commands, agents, hooks, agent settings and MCP server
  lists (`hidePaths`), so Copilot does not load another agent's workflows. `CLAUDE.md` and
  `.claude/rules` stay.
- `result.patch` next to the bundle, so a change can be read before it is fetched.
- `index.json`: every job's state in one file.
- `commit` in `job.json`: a job can start from an exact commit instead of a branch.
- `logs.ps1`: the end of a job's log and Copilot's last messages and commands, as JSON.
- Tools installed with `pip --user` are on a job's PATH.

### Changed

- `git branch` is off the read jobs' allow list.
- `RTFQ_*` variables are stripped from a job's environment.

## [0.2.0] - 2026-11-27

### Added

- Write jobs: a worktree on a new branch, all tools minus the deny list, and commits made as the
  identity the job names. When Copilot exits or is stopped, leftovers are committed, and the
  commits, changed files and diffstat go into `result.json`.
- `result.bundle`: a write job's branch as a git bundle, which is the only way work leaves the
  Copilot machine. The worktree stays until a `fetched` file appears, or seven days pass.
- The brief travels as `TASK.md` in the worktree, so its length is not bound by the command line.
- A default allow list for read jobs: git inspection, file reading, builds and tests.
- A second push guard, and a check of both: git's ssh command is one that does not exist, and
  before Copilot starts the worker tries a dry-run push against each guard and fails the job if
  one gets through.
- `models.json`: the models Copilot offers, with prices.
- A stopped job reports a lower bound for its credits where Copilot left a trace.
- The client scripts: `submit`, `wait`, `result`, `fetch`, `abort`, `discard` and `models`.

## [0.1.0] - 2026-11-27

### Added

- The runner: a scheduled task in the logged-on session of the machine that has Copilot CLI. It
  polls `jobs\<id>` folders and starts one worker per job, up to a concurrency limit.
- Read jobs: a detached worktree of `origin/<base>`, an environment stripped of secret-looking
  variables, deny rules, a git push guard, and every MCP server switched off.
- Cancel markers, timeouts, a credit cap per job, a heartbeat and a janitor.
- `tests/smoke.ps1`: a real runner against a stand-in for Copilot.

[Unreleased]: https://github.com/a7ex-turcan/rtfx/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/a7ex-turcan/rtfx/releases/tag/v0.3.1
