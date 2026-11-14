FROM alpine:3.22

RUN apk add --no-cache bash kubectl openssl yq-go

COPY --chmod=755 pipeline/configure.sh /usr/local/bin/configure.sh

ENTRYPOINT ["/usr/local/bin/configure.sh"]
