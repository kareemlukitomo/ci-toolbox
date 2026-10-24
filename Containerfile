# syntax=docker/dockerfile:1
#
# ci-toolbox - pinned, checksum-verified CI tools for the kareem.one self-hosted runners.
# initContainer usage: mount a shared emptyDir at /ci-tools and let this image copy the toolbox:
#   initContainers: [{name: ci-tools, image: registry.kareem.one/infra/ci-toolbox:TAG, volumeMounts: [{name: ci-tools, mountPath: /ci-tools}]}]
#
# All downloads are pinned by version in versions.env and verified with sha256sum -c.
# The final stage keeps only the binaries, versions.env and MANIFEST.

ARG ALPINE_IMAGE=alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f

FROM ${ALPINE_IMAGE} AS fetch

ARG TARGETARCH=amd64

RUN if [ "${TARGETARCH}" != "amd64" ]; then \
      echo "ci-toolbox supports linux/amd64 only, got ${TARGETARCH}" >&2; \
      exit 1; \
    fi

RUN apk add --no-cache ca-certificates coreutils curl tar unzip

WORKDIR /src
COPY versions.env /src/versions.env

RUN set -eux; \
    . /src/versions.env; \
    mkdir -p /src/dl /opt/ci-tools/bin; \
    cd /src/dl; \
    get() { \
      curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -o "$1" "$2"; \
      printf '%s  %s\n' "$3" "$1" | sha256sum -c -; \
    }; \
    get trivy.tar.gz \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
      "${TRIVY_SHA256}"; \
    get actionlint.tar.gz \
      "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
      "${ACTIONLINT_SHA256}"; \
    get gitleaks.tar.gz \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
      "${GITLEAKS_SHA256}"; \
    get bun.zip \
      "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64-musl.zip" \
      "${BUN_SHA256}"; \
    get kubectl \
      "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      "${KUBECTL_SHA256}"; \
    get helm.tar.gz \
      "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
      "${HELM_SHA256}"; \
    get jq-linux-amd64 \
      "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64" \
      "${JQ_SHA256}"; \
    get yq_linux_amd64 \
      "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
      "${YQ_SHA256}"

RUN set -eux; \
    cd /src/dl; \
    tar -xzf trivy.tar.gz trivy; \
    tar -xzf actionlint.tar.gz actionlint; \
    tar -xzf gitleaks.tar.gz gitleaks; \
    tar -xzf helm.tar.gz linux-amd64/helm; \
    unzip -qo bun.zip -d bun; \
    install -m 0755 trivy actionlint gitleaks kubectl jq-linux-amd64 yq_linux_amd64 /opt/ci-tools/bin/; \
    install -m 0755 linux-amd64/helm /opt/ci-tools/bin/helm; \
    install -m 0755 bun/bun-linux-x64-musl/bun /opt/ci-tools/bin/bun; \
    mv /opt/ci-tools/bin/jq-linux-amd64 /opt/ci-tools/bin/jq; \
    mv /opt/ci-tools/bin/yq_linux_amd64 /opt/ci-tools/bin/yq; \
    rm -rf /src/dl

RUN set -eu; \
    . /src/versions.env; \
    { \
      printf '# tool version binary_sha256 artifact_sha256\n'; \
      printf 'trivy %s %s %s\n' "${TRIVY_VERSION}" "$(sha256sum /opt/ci-tools/bin/trivy | cut -d' ' -f1)" "${TRIVY_SHA256}"; \
      printf 'actionlint %s %s %s\n' "${ACTIONLINT_VERSION}" "$(sha256sum /opt/ci-tools/bin/actionlint | cut -d' ' -f1)" "${ACTIONLINT_SHA256}"; \
      printf 'gitleaks %s %s %s\n' "${GITLEAKS_VERSION}" "$(sha256sum /opt/ci-tools/bin/gitleaks | cut -d' ' -f1)" "${GITLEAKS_SHA256}"; \
      printf 'bun %s %s %s\n' "${BUN_VERSION}" "$(sha256sum /opt/ci-tools/bin/bun | cut -d' ' -f1)" "${BUN_SHA256}"; \
      printf 'kubectl %s %s %s\n' "${KUBECTL_VERSION}" "$(sha256sum /opt/ci-tools/bin/kubectl | cut -d' ' -f1)" "${KUBECTL_SHA256}"; \
      printf 'helm %s %s %s\n' "${HELM_VERSION}" "$(sha256sum /opt/ci-tools/bin/helm | cut -d' ' -f1)" "${HELM_SHA256}"; \
      printf 'jq %s %s %s\n' "${JQ_VERSION}" "$(sha256sum /opt/ci-tools/bin/jq | cut -d' ' -f1)" "${JQ_SHA256}"; \
      printf 'yq %s %s %s\n' "${YQ_VERSION}" "$(sha256sum /opt/ci-tools/bin/yq | cut -d' ' -f1)" "${YQ_SHA256}"; \
    } > /opt/ci-tools/MANIFEST; \
    cp /src/versions.env /opt/ci-tools/versions.env; \
    for tool in trivy actionlint gitleaks bun kubectl helm jq yq; do \
      test -x "/opt/ci-tools/bin/${tool}"; \
    done

FROM ${ALPINE_IMAGE} AS runtime

# ca-certificates: trivy and helm need a trust store. libstdc++: bun musl build needs the C++ runtime.
# The busybox applets for network fetch and archive extraction are removed, so nothing in this
# image can download a tool at run time. /bin/sh, cp, mkdir, chmod and cat stay: the entrypoint
# needs them to copy the tree. apk-tools stays because it ships in the alpine base.
RUN apk add --no-cache ca-certificates libstdc++ \
    && rm -f /usr/bin/wget /usr/bin/unzip /usr/bin/ssl_client

COPY --chown=65532:65532 --from=fetch /opt/ci-tools /opt/ci-tools
COPY entrypoint.sh /usr/local/bin/ci-toolbox-init
RUN chmod 0755 /usr/local/bin/ci-toolbox-init \
    && mkdir -p /ci-tools \
    && chown 65532:65532 /ci-tools

ARG CI_TOOLBOX_REVISION=unknown
LABEL org.opencontainers.image.title="ci-toolbox" \
      org.opencontainers.image.description="Pinned CI tool binaries for the kareem.one self-hosted runners" \
      org.opencontainers.image.source="https://github.com/kareemlukitomo/ci-toolbox" \
      org.opencontainers.image.revision="${CI_TOOLBOX_REVISION}"

ENV PATH=/opt/ci-tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV CI_TOOLS_TARGET=/ci-tools

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/ci-toolbox-init"]
CMD ["/ci-tools"]
