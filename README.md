# ci-toolbox

Pinned CI tool binaries for the kareem.one self-hosted runners.

The image bakes each tool once. A runner pulls one image from the local registry instead of
downloading eight archives from the public internet on every workflow run.

Tools: trivy, actionlint, gitleaks, kubectl, helm, bun, jq, yq.

## Layout

| Path | Content |
| --- | --- |
| `/opt/ci-tools/bin` | the eight binaries |
| `/opt/ci-tools/versions.env` | pinned versions and artifact checksums |
| `/opt/ci-tools/MANIFEST` | tool, version, binary sha256, artifact sha256 |

The image runs as uid 65532. It contains no curl, no package manager at run time and no build
tools. The only shell is `/bin/sh`, and the entrypoint needs it to copy the tree.

## Publish

The push credential for `registry.kareem.one` lives in GitHub Actions secrets, not on an
operator host. Publishing therefore runs in GitHub Actions.

```bash
gh workflow run publish.yml --repo kareemlukitomo/ci-toolbox
gh run watch --repo kareemlukitomo/ci-toolbox
```

`.github/workflows/publish.yml` is manual only (`workflow_dispatch`). It runs on
`ubuntu-latest`, logs in to `registry.kareem.one`, builds `linux/amd64`, smoke tests the eight
binaries, and pushes two tags:

- `sha-<12 hex of the built commit>`
- `latest`

No artifact upload, no cache export to GitHub, no push on `push` or `tag` events. Pass
`dry_run: true` to build and smoke test without pushing. A dry run needs no secret.

The workflow needs two repository secrets:

| Secret | Value |
| --- | --- |
| `HARBOR_USERNAME` | robot account with push on the Harbor project `infra` |
| `HARBOR_PASSWORD` | token of that robot account |

Set them once:

```bash
gh secret set HARBOR_USERNAME --repo kareemlukitomo/ci-toolbox
gh secret set HARBOR_PASSWORD --repo kareemlukitomo/ci-toolbox
```

The first workflow step fails with an explicit message when either secret is empty. Without a
push-capable robot, the Harbor push fails with
`unauthorized: project infra not found: project infra not found`.

## Build locally

```bash
NO_PUSH=1 ./build.sh    # build, tag sha-<12 hex> and latest, then stop
./build.sh              # build, tag, then attempt the push with the local credential
```

`build.sh` uses the first engine it finds in this order: docker, podman, buildah. Set
`ENGINE=podman` to force one. Set `REGISTRY`, `REPOSITORY` or `PLATFORM` to override the
defaults `registry.kareem.one`, `infra/ci-toolbox` and `linux/amd64`.

The base image digest is the `ALPINE_IMAGE` build argument in `Containerfile`. Bump it with
`--build-arg ALPINE_IMAGE=alpine:3.22@sha256:<new digest>` and then write the new value into
the file.

## Bump a version

1. Open `versions.env` and change the version value.
2. Download the exact artifact for that version.
3. Run `sha256sum <artifact>` and paste the real digest into `versions.env`.
4. Run `NO_PUSH=1 ./build.sh`. The build stops if a digest does not match.
5. Run the image and check the tool version.
6. Commit both files together.

Do not write a digest that you did not compute from the downloaded artifact. Do not write a
version without its digest.

## Versions in this commit

| Tool | Version | Source |
| --- | --- | --- |
| trivy | 0.70.0 | GitHub release `trivy_0.70.0_Linux-64bit.tar.gz` |
| actionlint | 1.7.12 | GitHub release `actionlint_1.7.12_linux_amd64.tar.gz` |
| gitleaks | 8.28.0 | GitHub release `gitleaks_8.28.0_linux_x64.tar.gz` |
| bun | 1.3.9 | GitHub release `bun-linux-x64-musl.zip` |
| kubectl | 1.37.1 | `dl.k8s.io` current stable |
| helm | 4.3.1 | `get.helm.sh` current stable |
| jq | 1.8.2 | GitHub release `jq-linux-amd64` current stable |
| yq | 4.54.1 | GitHub release `yq_linux_amd64` current stable |

trivy, actionlint, gitleaks and bun match the versions the pt-mahkota workflows pin today.

kubectl 1.37.1 is the current stable release. The TKE cluster server is `v1.34.1-tke.8`, which
is three minors behind the client and outside the supported one-minor skew. If a CD job reports
a version skew, rebuild with `KUBECTL_VERSION=1.34.1` and
`KUBECTL_SHA256=7721f265e18709862655affba5343e85e1980639395d5754473dafaadcaa69e3`.

## Use in a workflow

The image works as an initContainer on the self-hosted ARC runners. The initContainer copies
`/opt/ci-tools` into a shared `emptyDir`, then each step adds `/ci-tools/bin` to `PATH`.

1. Add the volume and the initContainer to the runner scale set pod template.
2. Mount the same volume in the runner container at `/ci-tools`.
3. Set `PATH` in the step that needs a tool.

```yaml
# ARC runner scale set pod template (values: template.spec)
initContainers:
  - name: ci-tools
    image: registry.kareem.one/infra/ci-toolbox:latest
    args: ["/ci-tools"]
    volumeMounts:
      - name: ci-tools
        mountPath: /ci-tools
containers:
  - name: runner
    volumeMounts:
      - name: ci-tools
        mountPath: /ci-tools
volumes:
  - name: ci-tools
    emptyDir: {}
```

```yaml
jobs:
  verify:
    runs-on: [self-hosted, linux, x64]
    steps:
      - run: trivy --version
        env:
          PATH: /ci-tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

A workflow job container (`jobs.<id>.container`) does not share the runner pod volumes. For
those jobs, pass the toolbox directory through a mount that GitHub Actions can see, or run the
tools from the image with `docker run --rm <image> <tool>`.

The entrypoint has two modes. With no argument, or with `-`, it copies the toolbox to
`CI_TOOLS_TARGET` (default `/ci-tools`). With a path that is not an existing file as the first
argument, it copies the toolbox to that path. With any other argument, it runs that argument as
a command, so `docker run --rm <image> trivy --version` works.

The copy is additive: it overwrites files with the same name and keeps other files.

The volume must be writable by uid 65532. A Kubernetes `emptyDir` is created with mode 0777 and
needs no change. A host bind mount is created with the mode of the host directory, so either
run `chmod 0777` on that directory, set `fsGroup`, or run the initContainer as root with
`securityContext.runAsUser: 0`. When the volume is not writable, the entrypoint stops with
exit 73 and prints the required mode.

## Verify a published image

```bash
docker run --rm registry.kareem.one/infra/ci-toolbox:latest trivy --version
docker run --rm registry.kareem.one/infra/ci-toolbox:latest cat /opt/ci-tools/MANIFEST
```

Expected `MANIFEST` format:

```text
# tool version binary_sha256 artifact_sha256
trivy 0.70.0 <sha256 of the installed binary> <sha256 of the downloaded archive>
```

The third column is the digest that `Containerfile` checks with `sha256sum -c`. The second
column is the digest of the binary in the image.

Read the tags that Harbor holds:

```bash
curl -s -u "$HARBOR_USERNAME:$HARBOR_PASSWORD" \
  https://registry.kareem.one/v2/infra/ci-toolbox/tags/list
```
