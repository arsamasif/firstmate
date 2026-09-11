# Documented apply command for the no-mistakes per-step agent timeout

Source: `docs/configuration.md` > "Per-step agent timeout (~/.no-mistakes/config.yaml)".
The command below is pasted verbatim from the doc; only `HOME` is pointed at a throwaway sandbox so the captain's real config is never touched.

```sh
tmp=$(mktemp ~/.no-mistakes/config.yaml.XXXXXX) && awk 'BEGIN{n=split("agent_timeout review_agent_timeout test_agent_timeout",k," ")} {for(i=1;i<=n;i++) if($0 ~ "^"k[i]":"){$0=k[i]": \"90m\""; seen[i]=1} print} END{for(i=1;i<=n;i++) if(!seen[i]) print k[i]": \"90m\""}' ~/.no-mistakes/config.yaml > "$tmp" && mv "$tmp" ~/.no-mistakes/config.yaml
```

### Case 1 - all three keys already present at 30m

A config a recent no-mistakes generated itself.

```yaml
# before
push_target: origin
agent_timeout: "30m"
review_agent_timeout: "30m"
test_agent_timeout: "30m"
log_level: info
```

```yaml
# after (command run twice)
push_target: origin
agent_timeout: "90m"
review_agent_timeout: "90m"
test_agent_timeout: "90m"
log_level: info
```

exit codes: first run=0 second run=0

parsed check: valid YAML: yes | agent_timeout='90m'(x1) review_agent_timeout='90m'(x1) test_agent_timeout='90m'(x1) | PASS

leftover staging files in sandbox ~/.no-mistakes: 0

### Case 2 - none of the keys present

The captain's real situation: a config an older no-mistakes wrote, which predates these keys.

```yaml
# before
push_target: origin
log_level: info
```

```yaml
# after (command run twice)
push_target: origin
log_level: info
agent_timeout: "90m"
review_agent_timeout: "90m"
test_agent_timeout: "90m"
```

exit codes: first run=0 second run=0

parsed check: valid YAML: yes | agent_timeout='90m'(x1) review_agent_timeout='90m'(x1) test_agent_timeout='90m'(x1) | PASS

leftover staging files in sandbox ~/.no-mistakes: 0

### Case 3 - last line has no trailing newline

The append branch must not concatenate onto the final line.

```yaml
# before
push_target: origin
log_level: info
# ^ (no trailing newline on the last line above)
```

```yaml
# after (command run twice)
push_target: origin
log_level: info
agent_timeout: "90m"
review_agent_timeout: "90m"
test_agent_timeout: "90m"
```

exit codes: first run=0 second run=0

parsed check: valid YAML: yes | agent_timeout='90m'(x1) review_agent_timeout='90m'(x1) test_agent_timeout='90m'(x1) | PASS

leftover staging files in sandbox ~/.no-mistakes: 0

## Installed binary exposes the three keys (documented precheck, run for real)

```console
$ ~/.no-mistakes/bin/no-mistakes --version
no-mistakes version v1.60.2 (eb4e379) 2026-08-29T21:51:31Z

$ strings ~/.no-mistakes/bin/no-mistakes | grep -Ec '^(agent_timeout|review_agent_timeout|test_agent_timeout): '
3

$ strings ~/.no-mistakes/bin/no-mistakes | grep -E '^(agent_timeout|review_agent_timeout|test_agent_timeout): '
agent_timeout: "30m"
review_agent_timeout: "30m"
test_agent_timeout: "30m"
```

The precheck the doc prescribes returns 3, so v1.60.2 carries all three keys in its own generated config template, each defaulting to `30m`.

## The captain's config was not touched

```console
$ sha256sum ~/.no-mistakes/config.yaml   # identical before and after all testing
0573d1f3b9a234da437eb72f74280c1c6cc60aa20b2a61593f444448c1db46a1  /home/pending/.no-mistakes/config.yaml

$ grep -Ec '^(agent_timeout|review_agent_timeout|test_agent_timeout):' ~/.no-mistakes/config.yaml
0
```

Nothing was upgraded and the daemon was not restarted; every apply-command case above ran against a throwaway `HOME`.
