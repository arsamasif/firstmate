# Generated ship brief: no-mistakes definition of done

Produced by the real generator:
```
FM_HOME=$DEMO bin/fm-brief.sh demo-no-mistakes demo-proj --mode no-mistakes
```

## data/demo-no-mistakes/brief.md - Definition of done (verbatim)

```markdown
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make `--intent` preserve all relevant content from this brief's `# Task` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Three firstmate-specific rules layer on top of that guidance:
- Bound every agent round a gate dispatches. When you answer a gate with fix, rebase, or document guidance, name the precise per-file change you expect and tell that round to make it and STOP: no test-suite runs, no build or engine launches, and no other long-running project tooling inside the step.
  Each round runs under a wall-clock agent timeout, and a round that spends that budget re-verifying instead of editing is killed with some, all, or none of its work committed; the pipeline runs the suites itself at the steps that own them.
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid `--yes`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.
```

## The rule is absent from the briefs that dispatch no pipeline rounds

```
direct-PR    round-bounding rule present? no (expected)
local-only   round-bounding rule present? no (expected)
no-mistakes  round-bounding rule present? YES (expected)
```

## Negative controls - the new test actually fails when the behavior regresses

Both mutations were applied to `bin/fm-brief.sh`, the suite re-run, then the generator restored (`git diff` clean).

```console
# 1. rule deleted from the no-mistakes DOD
$ bash tests/fm-brief.test.sh
not ok - no-mistakes DOD lost the round-bounding rule   (exit 1)

# 2. rule leaked into the direct-PR brief, which dispatches no pipeline rounds
$ bash tests/fm-brief.test.sh
not ok - direct-PR brief must not carry the pipeline round-bounding rule   (exit 1)

# unmutated tree
$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: no-mistakes DOD bounds every agent round a gate dispatches   (exit 0)
```
