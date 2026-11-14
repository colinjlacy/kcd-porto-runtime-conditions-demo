FROM ghcr.io/opentofu/opentofu:1.12.6 AS tofu

FROM alpine:3.22

RUN apk add --no-cache bash jq kubectl yq-go

COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu
COPY tofu /opt/tofu
COPY --chmod=755 pipeline/pipeline.sh /usr/local/bin/pipeline.sh

ENTRYPOINT ["/usr/local/bin/pipeline.sh"]
