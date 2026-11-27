# rtfx

[![CI](https://github.com/a7ex-turcan/rtfx/actions/workflows/ci.yml/badge.svg)](https://github.com/a7ex-turcan/rtfx/actions/workflows/ci.yml)

Lets Claude Code hand coding jobs to GitHub Copilot CLI running on another machine, the way it hands
work to a subagent. Claude writes the brief and reviews the result; Copilot does the typing, on its
own credits, in its own worktree. Work comes back as a git branch that nobody pushed.

There are two machines and two halves:

- **The runner** (`runner/`, PowerShell 7) lives on the *worker*: the Windows machine that has
  Copilot CLI. It watches a folder for jobs and starts one Copilot process per job.
- **The MCP server** (`src/Rtfx`, .NET 10, `rtfx.exe mcp`) runs next to Claude Code and gives it
  eleven tools: delegate, fan_out, wait, status, logs, result, diff, fetch, abort, discard, models.
  It talks to the runner with `scp` and `ssh`, and to nothing else.

`client/` holds PowerShell scripts that do the same by hand, as a fallback.

Contents: [Prerequisites](#prerequisites) · [Getting started](#getting-started) ·
[Settings](#settings) · [Tools](#tools) · [Models and credits](#models-and-credits) ·
[Job protocol](#job-protocol) · [Read jobs and write jobs](#read-jobs-and-write-jobs) ·
[What no job can do](#what-no-job-can-do) · [Client scripts](#client-scripts) ·
[Troubleshooting](#troubleshooting) · [Development](#development) · [Releasing](#releasing) ·
[License](#license)

## Prerequisites

On the worker:

- Windows with PowerShell 7 (`pwsh`), git, and an OpenSSH server you can log in to with a key.
- **Copilot CLI, signed in inside your interactive desktop session.** Copilot's sign-in belongs to
  the logged-on session: a process started over SSH has no credentials and cannot run a job. So the
  runner is not started over SSH. It is a scheduled task that runs in the logged-on session, which
  means it runs only while you are logged on there. Lock the screen if you like; do not log off.
- A checkout of every repository you want jobs in, all under one folder (`reposRoot`), each with an
  `origin` the worker can fetch from, and whatever those repositories need to build and test.

Next to Claude Code:

- Windows x64 with the .NET 10 runtime (the SDK, to build from source).
- `ssh`, `scp` and `git` on PATH, and an ssh host name for the worker that logs in without a
  prompt. The server runs ssh with `BatchMode=yes`, so a password prompt is a failure.
- A checkout of the same repositories, all under one folder (`RTFX_LOCAL_REPOS`), with the same
  folder names as on the worker. A write job commits under the git identity of that checkout, and
  `fetch` adds the job's branch to it.

## Getting started

### 1. Install the runner on the worker

From a [release](https://github.com/a7ex-turcan/rtfx/releases), with `gh` or the browser:

```powershell
gh release download --repo a7ex-turcan/rtfx --pattern 'rtfx-runner-*'
(Get-FileHash rtfx-runner-0.3.1.zip -Algorithm SHA256).Hash    # compare with the .sha256 file
Expand-Archive rtfx-runner-0.3.1.zip -DestinationPath C:\rtfx -Force
```

or from source, on the machine that has the clone:

```powershell
ssh <worker> "pwsh -NoProfile -Command New-Item -ItemType Directory -Force C:/rtfx"
scp runner/*.ps1 <worker>:C:/rtfx/
```

`C:\rtfx` is the runner's *root*: scripts, jobs, worktrees and logs all live there. Any
folder will do, as long as `RTFX_ROOT` names the same one later.

If your checkouts are not under the default `reposRoot`, say where they are, in `config.json` in
the root (all settings: [Settings](#settings)):

```json
{ "reposRoot": "D:\\Repos" }
```

Then, on the worker, in your desktop session:

```powershell
pwsh -NoProfile -File C:\rtfx\install-task.ps1          # register and start, or restart after an update
pwsh -NoProfile -File C:\rtfx\install-task.ps1 -Remove  # stop and unregister
```

It registers the task `\rtfx\rtfx runner` for your user, starts it at logon, restarts it within
five minutes if it dies, and prints the first heartbeat. Check that Copilot is signed in by running
`copilot` once in that same session.

### 2. Install the MCP server next to Claude Code

From a release:

```powershell
gh release download --repo a7ex-turcan/rtfx --pattern 'rtfx-server-*'
Expand-Archive rtfx-server-0.3.1-win-x64.zip -DestinationPath C:\Tools\rtfx -Force
C:\Tools\rtfx\rtfx.exe version
```

or from source:

```powershell
dotnet publish src\Rtfx -c Release -o dist
dist\rtfx.exe version
```

### 3. Register it with Claude Code

In the workspace that should have the tools:

```powershell
claude mcp add rtfx -e RTFX_HOST=<worker> -e RTFX_ROOT=C:/rtfx -e RTFX_LOCAL_REPOS=D:\Repos -- C:\Tools\rtfx\rtfx.exe mcp
```

or as an entry in that workspace's `.mcp.json`:

```json
{
  "mcpServers": {
    "rtfx": {
      "command": "C:\\Tools\\rtfx\\rtfx.exe",
      "args": ["mcp"],
      "env": { "RTFX_HOST": "<worker>", "RTFX_ROOT": "C:/rtfx", "RTFX_LOCAL_REPOS": "D:\\Repos" }
    }
  }
}
```

Or keep the settings in a `config.json` next to `rtfx.exe` and register the bare form,
`claude mcp add rtfx -- <path>\rtfx.exe mcp`:

```json
{ "remoteHost": "<worker>", "remoteRoot": "C:/rtfx", "localRepos": "D:\\Repos" }
```

### 4. A first job, end to end

In Claude Code, ask for it in words ("use rtfx to add tests for the mapping factory in my-repo"),
or follow what happens tool by tool:

```text
status()
  -> the runner is running, version 0.3.1, 0 jobs

delegate(repo: "my-repo", ticket: "ABC-123",
         task: "Add unit tests for ColumnMapping.Create. Done means: dotnet test passes ...")
  -> { "id": "20261127-140000-ab12", "state": "queued" }

wait(job_ids: ["20261127-140000-ab12"], timeout_s: 900)
  -> done, 1.1 credits

result(job_id: "20261127-140000-ab12")
  -> Copilot's report, the commits, the changed files, the guards, any warnings

diff(job_id: "20261127-140000-ab12")
  -> the change as a patch, read before anything touches your checkout

fetch(job_id: "20261127-140000-ab12")
  -> the branch rtfx/20261127-140000-ab12 now exists in D:\Repos\my-repo
```

`fetch` only adds a branch. It checks nothing out and never touches your working tree; reviewing,
merging and pushing the branch are yours to do. A job you do not want is dropped with `discard`.

The job cannot ask anything back, so the brief has to carry what to do, where, what done means and
how to verify it.

To try a tool without Claude Code:

```powershell
$env:RTFX_HOST = '<worker>'
pwsh -NoProfile -File tests\mcp-call.ps1 -Exe C:\Tools\rtfx\rtfx.exe -Tool status
```

## Settings

### The MCP server

From the environment (`-e NAME=value` on `claude mcp add`, or `env` in `.mcp.json`), then from an
optional `config.json` next to `rtfx.exe`, then the defaults. The file is the place for a machine's
own values: it is not part of a release zip, so an update leaves it alone.

| variable | in `config.json` | default | meaning |
| --- | --- | --- | --- |
| `RTFX_HOST` | `remoteHost` | `rtfx-worker` | ssh host of the worker, usually an alias in `~/.ssh/config` |
| `RTFX_ROOT` | `remoteRoot` | `C:/rtfx` | the runner's root there |
| `RTFX_LOCAL_REPOS` | `localRepos` | `%USERPROFILE%\source\repos` | this machine's checkouts: a write job commits under the git identity of `<here>\<repo>`, and fetch adds the job's branch to it |
| `RTFX_DEFAULT_MODEL` | `defaultModel` | `gpt-6-luna` | the model of a job that names none |
| `RTFX_CACHE` | `cache` | `%LOCALAPPDATA%\rtfx` | downloaded results, patches and bundles |
| `RTFX_RUNNER_SCRIPTS` | | none | tests only: with `RTFX_HOST=.` the root is a local folder, and this is where the runner's scripts are |

An unknown name in the file is an error, and the server says so on stderr instead of starting.

A job that leaves a field out gets: write mode, medium effort, 60 credits, 45 minutes.

### The runner: `config.json`

Optional, in the runner's root. It holds only the settings you change; the rest keep the defaults
at the top of `runner\lib.ps1`. An unknown name is an error, so a typo does not pass silently. A
list replaces the default list whole: to add one entry, copy the default and add to it. Restart
the task after a change (`install-task.ps1`).

| setting | default | meaning |
| --- | --- | --- |
| `reposRoot` | `%USERPROFILE%\source\repos` | the folder holding the worker's checkouts; a job's `repo` is a folder name in it |
| `copilot` | `copilot` | the Copilot CLI command |
| `maxConcurrent` | `3` | jobs running at once; the rest wait in the queue |
| `pollSeconds` | `3` | how often the runner looks at the jobs folder and writes its heartbeat |
| `defaultEffort` | `medium` | reasoning effort of a job that names none |
| `defaultMaxCredits` | `30` | credit cap of a `job.json` that names none (the MCP server always sends one: 60) |
| `maxCreditsPerJob` | `200` | the highest cap a job may ask for |
| `defaultTimeoutMin` | `45` | minutes before the runner stops a job that names no timeout |
| `maxTimeoutMin` | `240` | the longest timeout a job may ask for |
| `worktreeDays` | `7` | days an unfetched write job keeps its worktree and branch |
| `jobDays` | `14` | days a job's folder is kept |
| `janitorMinutes` | `60` | how often the janitor runs |
| `modelsTimeoutMin` | `10` | how long a refresh of the model list may take |
| `probeModel` | `gpt-6-luna` | the model the model-list refresh talks to; it only has to answer one word |
| `stripEnv` | `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*PASSWD*`, `*CRED*`, `*_PAT`, `*_PASS`, `*APIKEY*`, `*API_KEY*`, `ConnectionStrings__*`, `ROVO_MCP_BASIC`, `RTFQ_*` | variable names removed from every job's environment; wildcards, case-insensitive |
| `keepEnv` | `JF_USER`, `JF_PASS`, `NPM_TOKEN`, `NODE_EXTRA_CA_CERTS`, `NODE_USE_SYSTEM_CA` | names that survive the strip: the read-only package feeds and the CA settings builds need |
| `feedHosts` | `*.jfrog.io` | hosts of private NuGet feeds; a source in the repository's `Nuget.config` on one of them is given credentials |
| `feedUserVar` | `JF_USER` | the variable holding the feed user; it must also be in `keepEnv` |
| `feedPassVar` | `JF_PASS` | the variable holding the feed password or token; it must also be in `keepEnv` |
| `denyTools` | `git push`, `remote`, `config`, `worktree`, `stash`, `rebase`, `filter-branch`, `update-ref`, `reflog`, `gc`, `submodule`; `gh`, `bb`; `curl`, `wget`, `Invoke-RestMethod`, `Invoke-WebRequest`; `ssh`, `scp`, `sftp`; `docker`, `podman`; package publishing; scheduled tasks | Copilot deny rules for every job, as `shell(...)` rules; the exact list is in `runner\lib.ps1` |
| `hidePaths` | `.claude/skills`, `.claude/commands`, `.claude/agents`, `.claude/settings.json`, `.claude/settings.local.json`, `.mcp.json`, `.github/mcp.json`, `.github/skills`, `.github/agents`, `.github/hooks`, `.github/copilot`, `.agents` | tracked files no job sees |
| `readAllowTools` | git inspection (`log`, `diff`, `show`, `status`, `blame`, `grep`, `ls-files`, `rev-parse`, `describe`, `merge-base`); file reading and listing; `dotnet build`, `test`, `restore`; `pnpm install`, `test`, `run`; `node`, `python`, `pytest`, `uv` | what a read job may run with nobody there to approve it; the exact list is in `runner\lib.ps1` |

Private NuGet feeds need two user-level environment variables on the worker, named by
`feedUserVar` and `feedPassVar`. The runner reads them from its own environment, so restart the
task after setting them. The account needs read access to every repository the sources name.

## Tools

| tool | what it does |
| --- | --- |
| `delegate(task, repo, mode?, base?, commit?, model?, effort?, max_credits?, timeout_min?, ticket?, allow_tools?, wait_seconds?)` | starts one job and returns its id; with `wait_seconds` it waits and includes the result if the job ended in time |
| `fan_out(jobs[])` | starts several jobs, each with delegate's fields; all are checked before any is submitted |
| `wait(job_ids[], timeout_s?)` | returns when every job has ended or the time is up, with each job's state |
| `status(job_id?)` | one job, or the runner's health and the recent jobs |
| `logs(job_id, tail?)` | the end of the worker's log, Copilot's last messages and its last commands |
| `result(job_id)` | the final report, credits, commits, changed files, diffstat, guards and warnings |
| `diff(job_id, path?)` | the job's change as a patch, whole or for one path, before any fetch |
| `fetch(job_id, branch?)` | adds the job's branch to the local checkout; checks nothing out, and refuses a name that is taken |
| `abort(job_id)` | stops a job; a write job keeps the work it had done |
| `discard(job_id)` | drops an unwanted job's worktree and branch now |
| `models(refresh?)` | the models Copilot offers, with prices |

A job nobody will pick up is not queued: when the runner's heartbeat is more than two minutes old,
delegate says the runner is down and how to start it. When the worker does not answer over ssh, the
tools say that instead.

## Models and credits

Copilot bills in AI credits; one credit is 0.01 USD. `models` lists what it offers, with prices in
credits per million tokens.

| | default | limits |
| --- | --- | --- |
| model | `gpt-6-luna` (`RTFX_DEFAULT_MODEL`) | any id from `models` |
| effort | `medium` | `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` |
| credit cap | 60 | 30 (Copilot's minimum) to 200 (`maxCreditsPerJob`) |
| timeout | 45 minutes | up to 240 (`maxTimeoutMin`) |

The cap is soft. At nine tenths of it Copilot makes the next model call the last and takes the
tools away, so a job can end as `done` with its work cut short. Such a job is flagged
`nearCreditCap`: read its result with that in mind, and raise the cap or split the brief.

What has worked, from running the same tasks on several models:

- **Coding jobs: `gpt-6-luna`, medium effort.** It was correct on every task tried and the cheapest
  by far: a small fix costs one to five credits.
- **A wide change: improve the brief before reaching for a bigger model.** What separated answers
  from the real fix was knowledge the ticket did not state. Name the status codes, the headers, what
  gets logged, and every endpoint the fault touches.
- **A second opinion on a wide change: `claude-sonnet-5.5`.**
- **Reviews: `gpt-6.2-astra`, read mode, high effort, a cap of 150.** It is not the model for coding
  at medium effort under a tight cap: it spent 73 of 75 credits on a small fix.

## Job protocol

Everything lives under the runner's root on the worker:

```
jobs\<id>\job.json       the request
jobs\<id>\task.md        the brief
jobs\<id>\status.json    queued, running, done, failed, cancelled or timeout
jobs\<id>\cancel         create this file to stop the job
jobs\<id>\copilot.jsonl  Copilot's raw output
jobs\<id>\result.json    final report, credits, and for a write job the commits and the bundle
jobs\<id>\result.bundle  a write job's branch, as a git bundle
jobs\<id>\result.patch   the same change as text, for reading before a fetch
jobs\<id>\fetched        create this file once the bundle has been fetched
jobs\<id>\worker.log     what the worker did, including the names of the variables it removed
wt\<id>\                 the job's worktree
models.request           create this file to have models.json refreshed
models.json              the models Copilot offers, with prices
index.json               every job's state in one file, newest first
heartbeat.json           written by the runner every few seconds
runner.log
config.json              optional overrides, see Settings
```

To submit a job, write `job.json` and `task.md` first and `status.json` (`{"state":"queued"}`) last.
The runner picks a job up only once its status says queued. `client\submit.ps1` does this.

`job.json`:

| field | default | meaning |
| --- | --- | --- |
| `id` | folder name | letters, digits, `-` and `_` |
| `repo` | required | folder name of a checkout under `reposRoot` |
| `base` | `main` | branch the job starts from, read as `origin/<base>` |
| `commit` | none | an exact commit to start from instead, such as a pull request's head |
| `mode` | `write` | `read` or `write` |
| `model` | Copilot's own | Copilot model id, as listed in `models.json` |
| `effort` | `medium` | `none`, `minimal`, `low`, `medium`, `high`, `xhigh` or `max` |
| `maxCredits` | 30 | AI credit cap for the run; 30 is Copilot's minimum, 200 the runner's ceiling |
| `timeoutMin` | 45 | the runner stops the job after this long |
| `allowTools` | none | read jobs: extra Copilot allow rules, such as `shell(cargo test)`; deny rules still win |
| `gitName`, `gitEmail` | required for write | who the job's commits are made as |
| `ticket` | none | write jobs: a key such as `ABC-123`; every commit subject then starts `ABC-123: ` |
| `branch` | `rtfx/<id>` | write jobs: the new branch the job works on; it must not exist yet |

The brief can be any length: the worker puts it in the worktree as `TASK.md` (ignored by git through
the checkout's `info/exclude`) and the prompt tells Copilot to read it.

## Read jobs and write jobs

A **read job** gets a detached worktree of `origin/<base>` that is removed when it ends. Copilot may
run what it recognises as read-only, plus a fixed list (`readAllowTools`: git inspection, file
reading, `dotnet build` and `test`, `pnpm install`, `test` and `run`, `node`, `python`, `pytest`,
`uv`) and whatever the job adds with `allowTools`. Anything else is denied, since nobody is there to
approve it. Builds are on the list because they write only inside the throwaway worktree.

A **write job** gets a worktree on a new branch cut from `origin/<base>`, and all tools. When
Copilot exits, or is stopped by a cancel or a timeout, the worker:

1. commits whatever was left uncommitted, as `<ticket>: uncommitted changes left by the agent`;
2. records in `result.json` the commits on the branch, the changed files, the diffstat, the base
   commit, and whether the worktree was clean before step 1;
3. packs `<base commit>..<branch>` into `result.bundle`.

Any job that spent nine tenths or more of its credit cap is flagged: `nearCreditCap` in
`result.json`, `status.json` and the index, and a warning.

The worktree and the branch stay on the worker until a `fetched` file appears in the job folder, or
seven days pass. A job that committed nothing has nothing to fetch, so its worktree and branch go
at once. `result.json` also carries warnings: a commit subject without the ticket prefix, a commit
under another identity, a Co-authored-by trailer, an em dash in a message.

## What no job can do

- Its environment is stripped of every variable whose name looks like a secret (`stripEnv`). The
  package feed credentials and the CA settings that builds need are kept by name (`keepEnv`). The
  names removed are logged, never the values.
- The exception to the strip is NuGet: for each source in the repository's `Nuget.config` whose
  host is a private feed (`feedHosts`) the worker sets `NuGetPackageSourceCredentials_<source name>`
  from the kept feed user and password, because that is the only place NuGet reads them from the
  environment. They exist in the job's environment only; `result.json` names the sources under
  `feedSources`.
- No MCP server runs: the ones the user and the repository configure are switched off by name, and
  their tools denied.
- It does not see the repository's skills, commands, agents, hooks and settings for coding agents,
  nor its MCP server lists (`hidePaths`). Those are another agent's workflows, and Copilot would
  load them. The worker marks the files skip-worktree and deletes them from the worktree, so git
  reports nothing and a write job's commits leave them alone. `CLAUDE.md` and `.claude/rules` stay:
  they are the repository's conventions.
- Deny rules (`denyTools`) block `git push`, remotes, git config, history rewriting, `gh`, HTTP
  clients, ssh, docker, package publishing and scheduled tasks. Deny rules win over every allow.
- Git itself cannot push or reach the remote, whatever command asks it to: through the job's
  environment every push URL is rewritten to one that cannot work, and git's ssh command is one
  that does not exist. The worker fetches before it sets this up.
- Before Copilot starts, the worker tries a dry-run push itself, once against each of those two
  guards. If either try gets through, the job fails and Copilot is never started. `result.json`
  records the outcome under `guards`.
- A write job's commits are made as `gitName` and `gitEmail`, also set through the environment, so
  the checkout's own config is neither used nor touched.

These stop accidents, not a determined program. A job runs as the Windows user the runner runs as,
and a job that may run `node` or `python` can do what that user can: read files outside the
worktree, read the variables the strip removed back out of the registry, reach services on the
machine's own loopback. Copilot has an OS-level sandbox (`--sandbox`) that would close this; rtfx
does not use it.

## Client scripts

The same operations by hand, from a clone of this repository. They read `client\config.json` if it
exists, then `RTFX_HOST`, `RTFX_ROOT`, `RTFX_LOCAL_REPOS` and `RTFX_CACHE`. The defaults are in
`client\lib.ps1`. Each prints JSON.

```powershell
pwsh -NoProfile -File client\submit.ps1 -Repo <repo> -TaskFile brief.md -Ticket ABC-123 -MaxCredits 60
pwsh -NoProfile -File client\submit.ps1 -Repo <repo> -Mode read -Task 'What does the README cover?'
pwsh -NoProfile -File client\wait.ps1   -Id <id>                 # exit 0 done, 2 ended otherwise, 3 still going
pwsh -NoProfile -File client\result.ps1 -Id <id> [-Report]
pwsh -NoProfile -File client\fetch.ps1  -Id <id> -Target <local checkout>
pwsh -NoProfile -File client\abort.ps1  -Id <id>
pwsh -NoProfile -File client\discard.ps1 -Id <id>                # work not wanted: drop its worktree and branch now
pwsh -NoProfile -File client\models.ps1 [-Refresh]
```

`submit` takes the commit identity of a write job from `-GitName` and `-GitEmail`, or from the git
config of this machine's own checkout of the repository.

`fetch` downloads the bundle, checks its hash against `result.json`, checks with `git bundle verify`
that the target has the commit the job started from, fetches the branch, and writes `fetched` on the
runner. It only adds a branch: it never checks anything out, never touches the working tree, and
refuses to move a branch that already exists somewhere the bundle does not continue.

`models` prints `models.json`. Copilot has no command that lists its models with prices, but it logs
the catalog it downloads at debug level. So the runner, when asked, runs one tiny prompt with a
debug log, takes the catalog out of it, and deletes the log in the same step, because a debug log
can hold request headers. The client asks for a refresh when the list is more than seven days old.

## Troubleshooting

| what you see | what it means, and what to do |
| --- | --- |
| "The runner ... is not running: its last heartbeat is ... old" | Nobody is logged on at the worker, or the task was stopped. Log on there and run `install-task.ps1`. The task comes back by itself at the next logon. |
| "The runner ... has never written a heartbeat" | The runner is not installed in that folder, or `RTFX_ROOT` names another one. |
| The tools say the worker does not answer over ssh | Try `ssh -o BatchMode=yes <worker> "pwsh -NoProfile -Command Get-Date"`. It has to print the date without asking anything: key login, and `pwsh` on the worker's PATH. |
| A job fails within seconds | `logs(job_id)`. Usually Copilot is not signed in in the desktop session (run `copilot` there and sign in), the repository is not under `reposRoot`, or the branch or commit does not exist on the worker. |
| A write job is refused: "no checkout ... to take the commit identity from" | The local checkout `<RTFX_LOCAL_REPOS>\<repo>` is missing, or has no `user.name` and `user.email` in its git config. |
| `done`, but `nearCreditCap` | The job hit its cap and may have stopped early. Raise `max_credits` or split the brief. |
| A read job reports "Permission denied because no interactive user response was available" | Copilot wanted an approval. The command is not on the allow list (add it with `allow_tools`), or it redirects output (`2>&1`, `> file`), which read mode always refuses. |
| `dotnet restore` gets 401 or 403 from a private feed | 401: the feed variables are missing on the worker or the task was not restarted since they were set. 403: the account has no read access to that feed repository. `result.json` lists the sources that were given credentials under `feedSources`. |
| `fetch` refuses the branch name | It exists locally and the job's branch does not continue it. Pass another `branch`. |
| `fetch` says the base commit is missing | The local checkout is behind the worker's. `git fetch` in it and try again. |
| No heartbeat after a change to `config.json` | A misspelt setting name stops the runner as it starts. Run `pwsh -NoProfile -File <root>\runner.ps1` by hand to see `config.json: unknown setting '...'`, fix it, and run `install-task.ps1` again. |
| The tools are missing in Claude Code, or still the old version | Run `/mcp` and reconnect rtfx. After replacing `rtfx.exe` the server has to be restarted to load it. |
| The smoke test fails on waits | Its waits assume git starts in well under a second. On a loaded machine, run it again. |

Updating: copy the new runner scripts over the old ones and run `install-task.ps1` again; replace
`rtfx.exe` and reconnect the MCP server. Both halves say their version: `status()` shows the
runner's, `rtfx.exe version` the server's.

## Development

```powershell
dotnet build                             # warnings are errors
dotnet test                              # the MCP server: parsing, validation, the protocol, fetch
pwsh -NoProfile -File tests\smoke.ps1    # the runner, the client scripts and the MCP server together
```

The smoke test starts a real runner on a temp folder with `tests\fake-copilot.ps1` standing in for
Copilot, and drives it directly, through the client scripts, and through `rtfx mcp` over its real
protocol (build first, or that part is skipped). It checks the queue, the concurrency limit, cancel,
timeout, the stripped environment, the push guard, the hidden files, read and write jobs, the bundle
and its fetch into a second clone, a stopped write job keeping its work, the model list, recovery
after a runner restart and the janitor.

The integration tests run real jobs on the worker and spend about one credit. They are skipped
unless asked for:

```powershell
$env:RTFX_INTEGRATION = '1'
$env:RTFX_INTEGRATION_REPO = 'my-repo'           # a repository both machines have
$env:RTFX_LOCAL_REPOS = 'C:\scratch\repos'       # a scratch folder holding a clone of it, never the real checkouts
dotnet test --filter-class Rtfx.Tests.IntegrationTests
```

`tests\mcp-call.ps1 -Tool <name> -Arguments '<json>'` calls one tool of the server by hand.

CI (`.github/workflows/ci.yml`) runs on every push and pull request to `main`, on a Windows runner:
restore, build, the unit tests, the smoke test, then the release checks below without publishing
anything.

## Releasing

The server and the runner carry one version and are released together. Pushing a tag `v<version>`
runs `.github/workflows/release.yml`, which builds, tests, packages and publishes a GitHub Release
using only the workflow's own `GITHUB_TOKEN`:

- `rtfx-server-<version>-win-x64.zip`: the MCP server, as `dotnet publish src\Rtfx -c Release` makes it
- `rtfx-runner-<version>.zip`: the runner's scripts
- a `.sha256` file next to each, in `sha256sum`'s format
- the release notes: the section of [CHANGELOG.md](CHANGELOG.md) for that version

To cut one:

1. In `CHANGELOG.md`, move what is under `## [Unreleased]` into a new `## [<version>] - <date>`
   section, and update the links at the bottom.
2. Set the version in both `src\Rtfx\Rtfx.csproj` (`<Version>`) and `runner\lib.ps1`
   (`$RtfxVersion`).
3. Check it on your desk:

   ```powershell
   pwsh -NoProfile -File build\release-notes.ps1    # prints the notes the release will carry
   pwsh -NoProfile -File build\package.ps1          # builds the zips into artifacts\
   ```

4. Commit, push, and wait for CI to pass on `main`.
5. Tag and push the tag:

   ```powershell
   git tag v<version>
   git push origin v<version>
   ```

The release fails, and publishes nothing, when the tag is not `v` plus the project version, when
the server and the runner disagree on the version, or when `CHANGELOG.md` has no section for the
version or an empty one. A tag with a suffix, such as `v0.4.0-rc1`, is published as a pre-release.

## License

[MIT](LICENSE)
