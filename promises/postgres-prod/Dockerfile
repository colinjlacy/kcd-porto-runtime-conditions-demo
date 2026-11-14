FROM alpine:3.22

RUN apk add --no-cache bash jq kubectl openssl postgresql17-client yq-go

COPY --chmod=755 pipeline/pipeline.sh /usr/local/bin/pipeline.sh

ENTRYPOINT ["/usr/local/bin/pipeline.sh"]
