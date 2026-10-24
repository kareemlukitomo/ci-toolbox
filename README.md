# ci-toolbox

Pinned CI tool binaries for the kareem.one self-hosted runners.

The image bakes each tool once. A runner pulls the image from the local registry instead of
downloading eight archives from the public internet on every workflow run.

Tools: trivy, actionlint, gitleaks, bun, kubectl, helm, jq, yq.

## Layout

| Path | Content |
| --- | --- |
| `/opt/ci-tools/bin` | the eight binaries |
| `/opt/ci-tools/versions.env` | pinned versions and artifact checksums |
| `/opt/ci-tools/MANIFEST` | tool, version, binary sha256, artifact sha256 |

The image runs as uid 65532 and contains no curl, no package manager use at run time and no
build tools.

## Build

```bash
./build.sh              # build, tag <date-or-tag>-<short sha> and latest, then push
NO_PUSH=1 ./build.sh    # build and tag only
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

## Publish

```bash
docker login registry.kareem.one   # a robot account with push rights for infra/ci-toolbox
./build.sh
```

`build.sh` pushes `<date-or-tag>-<short sha>` and `latest`. It never runs an interactive login
and never prints a token. A 401 or 403 from the registry stops the script with exit code 3.

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

## Versions in this commit

| Tool | Version |
| --- | --- |
| trivy | 0.70.0 |
| actionlint | 1.7.12 |
| gitleaks | 8.28.0 |
| bun | 1.3.9 |
| kubectl | 1.34.1 |
| helm | 4.3.1 |
| jq | 1.8.2 |
| yq | 4.54.1 |

kubectl matches the cluster server version `v1.34.1-tke.8` at pin time.
