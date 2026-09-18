# The pre-push gate

This repository is public. A secret that reaches GitHub is burned the second it
lands, and no later commit takes it back: it is cloned, mirrored and indexed
before anyone notices. The gate described here is the last thing standing
between a careless paste and that.

It is not hypothetical. Read the `.gitignore`: `*.bak`, `*.bak-*`, `*.ubak` and
`*.orig` are excluded by name because the control script was scrubbed of the
addresses and the API key it carried, and an editor backup would have published
the version before the scrub. The same file excludes benchmark inputs and test
fixtures, which are the other way a real document reaches a public repository.

## What runs, and when

`git push` runs `.githooks/pre-push`, which runs two scans. They do not look at
the same thing, and dropping either one leaves a real case uncovered.

`scripts/history-scan.sh` runs gitleaks over the commits the push is about to
send. git hands the hook one line per ref on standard input, `<local ref>
<local sha> <remote ref> <remote sha>`, and each `<remote sha>..<local sha>`
becomes a range to read. An all-zero remote sha means the branch is new over
there, so the whole reachable history is read instead. An all-zero local sha is
a ref being deleted, which sends no object and is skipped.

`scripts/security-scan.sh` runs Trivy over the whole working tree: plaintext
secrets, misconfigurations, and dependency advisories should this repository
ever grow a manifest.

Neither scan covers the other, which is why both run. Trivy reads the
FILESYSTEM as it stands now, so a key added by one commit and removed by the
next is invisible to it, and both commits still leave in the same push: the
file looks clean, the history carries the key, and GitHub indexes the history.
Gitleaks reads the object graph, so it sees what is actually sent. It costs
89 ms over the 2 commits of this repository, measured on 2026-09-18.

Trivy gives two verdicts, not one. Any CRITICAL blocks, whether or not a fix
exists upstream. A HIGH blocks only once a fix is published, because blocking on
a flaw nobody can fix teaches people to ignore the red, which is how a real
finding eventually gets waved through. Everything else is printed and lets the
push proceed.

Both scans fail closed. For Trivy, exit code 2 means findings; every other
non-zero code means the scan itself broke, and the push is refused with a
message saying so. A scan that could not run must never read as a clean scan.

Gitleaks needs more than its exit code, because it has a failure mode that looks
exactly like success. Measured on 2026-09-18: pointed at a directory it cannot
read as a repository, it prints one error line, scans zero commits, reports
`no leaks found` and exits 0. So `history-scan.sh` also refuses the push when
the output carries a git `fatal:` line, or when no commit count comes back at
all. The case that produced this is a linked worktree, where `.git` is a file
pointing at a directory outside the mount; the script now mounts that directory
at its own absolute path.

## Wiring it in a fresh clone

    ./scripts/install-hooks.sh

Run it once per clone and once per worktree. `core.hooksPath` is a repository
setting, so a fresh clone has none and every hook in `.githooks` is dead until
this runs, silently. The script prints what git actually resolved rather than
claiming success, so you can see the wiring rather than trust it.

There is no husky here and there will not be one: no Node manifest, hence no
`pnpm install` to hang a `prepare` script on. The plain versioned hook does the
same job with nothing to install.

## Requirements

Docker, and access to the private registry that holds the pinned Trivy image.
Trivy always runs in that image, never from a binary installed on the machine,
so the version deciding a push here is the one deciding it everywhere else. A
floating public tag would change content under us and make a verdict impossible
to reproduce. The gitleaks image is pinned by digest for the same reason, but
comes from Docker Hub, so the history scan keeps working from a clone with no
VPN.

The vulnerability database lives in a named Docker volume,
`llm-station-trivy-cache`, shared with the sibling stations. Without it every
run would download the database again, which turns a scan of a few seconds into
one of a few minutes and makes the hook something people work around.

## When it blocks

A leaked secret is not fixed by editing the file. Rotate it first, then remove
it, then rewrite the history that holds it. Editing the file only hides it from
the tree scan, and the history scan will still refuse the push, which is the
point: the commit carries the key whatever the file says now.

Anything else: raise the dependency or fix the configuration. If the fix breaks
the station, open an issue and write the line in `.trivyignore` with its
re-audit date, never a bare entry that stays silent forever.

`git push --no-verify` exists and this repository will not pretend otherwise.
It sends the finding to a public remote where nothing else will stop it.

## Proof it works

The gate was built and proven on the CUDA station on 2026-09-18, then copied
here unchanged. There, a file carrying an AWS key pair made Trivy report
`AWS Access Key ID` and the hook exit non-zero; a throwaway clone where one
commit added a key pair and the next deleted the file passed the tree scan and
was caught by the history scan, `leaks found: 2`. Four ways of breaking the scan
all refused the push: Docker missing from the PATH (127), an unpullable image
(125), an unreadable worktree, and a missing commit count.

On this repository, gitleaks over the full history found no leak across its 2
commits. The API key scrubbed from the control script had never been committed.
