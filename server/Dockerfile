# syntax=docker/dockerfile:1
# The PicTunnel server image: a static pictunnel binary on Alpine with ffmpeg
# (HEIC, RAW and video thumbnails, video metadata and transcodes).
#   docker build -t pictunnel server/        (or: task proto:up)

FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
ARG VERSION=dev
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/pictunnel ./cmd/pictunnel

FROM alpine:3.22
RUN apk add --no-cache ca-certificates ffmpeg tzdata \
 && addgroup -S -g 10001 pictunnel \
 && adduser -S -D -H -u 10001 -G pictunnel pictunnel \
 && mkdir -p /data \
 && chown pictunnel:pictunnel /data
COPY --from=build /out/pictunnel /usr/local/bin/pictunnel
USER pictunnel
# The data dir (database, keys, TLS material, library) is a volume.
ENV PICTUNNEL_DATA_DIR=/data
VOLUME ["/data"]
# 8443: HTTPS for phones and browsers. The loopback listener (127.0.0.1:8080)
# stays inside the container; `pictunnel pair` uses it through docker exec.
EXPOSE 8443
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["pictunnel"]
CMD ["serve"]
