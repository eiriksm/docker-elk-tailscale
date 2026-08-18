# Runs the seed and verify scripts. Living on the compose network means the
# scripts talk to http://elasticsearch:9200 directly, so no port has to be
# published to the host for testing, and CI and a laptop run byte-identical
# tooling regardless of what is installed on either.
FROM alpine:3.22

RUN apk add --no-cache bash curl jq coreutils

WORKDIR /work
ENTRYPOINT ["/bin/bash"]
