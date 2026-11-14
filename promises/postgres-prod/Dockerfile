FROM alpine:3.22 AS tofu

ARG TARGETARCH
ARG TOFU_VERSION=1.12.6
ARG TOFU_SHA256_AMD64=5dc43da4f750f33873dc25e94587128709e819e544b7be9016b255316153c3a8
ARG TOFU_SHA256_ARM64=e573979ba68a17fe7b881752051a694a7efcd970e39521f6a25775197861ed4d

RUN apk add --no-cache curl unzip \
    && case "${TARGETARCH}" in \
         amd64) sha256="${TOFU_SHA256_AMD64}" ;; \
         arm64) sha256="${TOFU_SHA256_ARM64}" ;; \
         *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl -fsSLo /tmp/tofu.zip "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${TARGETARCH}.zip" \
    && echo "${sha256}  /tmp/tofu.zip" | sha256sum -c - \
    && unzip /tmp/tofu.zip tofu -d /usr/local/bin

FROM alpine:3.22

RUN apk add --no-cache bash jq kubectl yq-go

COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu
COPY tofu /opt/tofu
COPY --chmod=755 pipeline/pipeline.sh /usr/local/bin/pipeline.sh

ENTRYPOINT ["/usr/local/bin/pipeline.sh"]
