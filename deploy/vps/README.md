# Deploying this fork to the VPS

This folder is only for the fork that runs the self-hosted server (branch `vps/main`). It is not part
of the upstream project.

```
GitHub Actions ──(Tailscale)──> VPS
 test -> build (api, mcp, web) -> approval -> docker save | ssh "deploy <tag>"
                                               └─ deploy.sh: load, back up, swap api -> mcp -> web,
                                                  health check each, roll back on any failure
```

- `deploy.sh` runs on the server and is the only thing the CI key can run.
- `test-deploy.sh` tests it with a fake docker (`bash deploy/vps/test-deploy.sh`, Linux).
- `.github/workflows/vps-deploy.yml` is the pipeline.

## One-time setup

Short way: `bash deploy/vps/setup-pipeline.sh` (add `--check` to only look). It checks the restricted key,
pins the host key, enables Actions, creates the `production` environment, stores the six secrets and can
run and approve the first deploy; it walks you through the two Tailscale pages. The manual steps below
are what it does.

**1. SSH key for CI.** Make a key just for this and keep the private half out of the repo:

```
ssh-keygen -t ed25519 -N '' -C opengym-ci -f ./opengym-ci
```

**2. Install the script on the server by hand.** It must not be writable by the CI key.

```
sudo install -d -o <operator> /srv/apps/deploy
install -m 755 deploy/vps/deploy.sh /srv/apps/deploy/opengym-deploy.sh
```

Add one line to `~<operator>/.ssh/authorized_keys` (the public half of the key above):

```
command="/srv/apps/deploy/opengym-deploy.sh",restrict ssh-ed25519 AAAA... opengym-ci
```

`restrict` turns off forwarding, a terminal and agent use; `command=` makes every login run the
script, whatever the client asks for. Update the installed script by hand when this file changes.

**3. Tailscale.** In the admin console:

- ACL `tagOwners`: `"tag:ci": ["<you>"]`, and a grant that lets only that tag reach the server:
  `{"src": ["tag:ci"], "dst": ["<server>"], "ip": ["tcp:22"]}`.
- Settings, OAuth clients: create one with the `auth_keys` write scope and the tag `tag:ci`.

**4. Server host key.** Pin it so the job never trusts a new host on first contact. Compare the
fingerprint on the server first (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`), then:

```
ssh-keyscan -t ed25519 <tailnet name of the server>
```

If the server regenerates its host keys (a rebuilt VPS, or a reboot that does), update the secret.

**5. GitHub.** In the fork: enable Actions (forks start with it off), create the environment
`production` with yourself as required reviewer, and put these in that environment's secrets so only
the approved job can read them:

| Secret | Value |
|---|---|
| `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` | the Tailscale OAuth client |
| `VPS_DEPLOY_SSH_KEY` | the private key from step 1 |
| `VPS_KNOWN_HOSTS` | the line from step 4 |
| `VPS_HOST` | the server's tailnet name |
| `VPS_USER` | the operator user that owns `authorized_keys` |

Delete the local copy of the private key once it is in GitHub.

## Deploying

Actions, "VPS deploy", Run workflow on `vps/main` (or push a `vps-v*` tag). Tests and the image build
run first; the deploy job then waits for approval. The tag is `v<version>-<short sha>`.

What the server does, in order: checks free disk, loads the images, writes
`/srv/apps/deploy-backups/opengym-pre-<tag>-<time>/data.tgz`, creates
`/srv/apps/releases/opengym-<tag>` (compose files from the package, `.env` copied from the current
release with the new tag), swaps `api`, `mcp` and `web` one by one, waits for each to be healthy, checks
the public health URL, then moves `/srv/apps/opengym` to the new release. Any failure puts the
previous images back and leaves the link where it was.

## Rolling back

From anywhere that can SSH with the CI key, or on the server:

```
/srv/apps/deploy/opengym-deploy.sh rollback     # previous images, recorded by the last deploy
/srv/apps/deploy/opengym-deploy.sh status
```

A rollback does not touch data. To also restore the data, untar the backup of that deploy by hand,
which discards what was written since.

## Moving to a new upstream release

```
git fetch upstream --tags
git rebase --onto <new tag> <old tag> vps/main
```

Conflicts so far were additive (imports, `.env.example`, the api Dockerfile COPY list, locale packs):
keep both sides. Then run the three test suites and the pipeline.

## Known

- `frontend/src/lib/csp.test.js` fails on this branch on purpose: the `/mcp-authorize` block sends no
  Content-Security-Policy (the mcp service sets its own). The workflow leaves that one file out.
- Do not commit `.env`, keys or data. The fork is public.
