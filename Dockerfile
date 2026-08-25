FROM alpine:3.24

RUN apk add --no-cache \
    mysql-client \
    tzdata

ENTRYPOINT ["crond", "-f"]
