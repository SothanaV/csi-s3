FROM golang:1.16-alpine as gobuild

WORKDIR /build
ADD . /build

# go get would upgrade to latest (incl. retracted) versions, resolve from go.sum instead
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -a -ldflags '-extldflags "-static"' -o ./s3driver ./cmd/s3driver

FROM debian:buster-slim
LABEL maintainers="Cyrill Troxler <cyrilltroxler@gmail.com>"
LABEL description="csi-s3 slim image"

# buster is EOL, its packages now live on archive.debian.org
RUN sed -i -e 's|deb.debian.org|archive.debian.org|g' \
  -e 's|security.debian.org|archive.debian.org|g' \
  -e '/buster-updates/d' /etc/apt/sources.list

# s3fs and some other dependencies
RUN apt-get update -o Acquire::Check-Valid-Until=false && \
  apt-get install -y \
  s3fs curl unzip && \
  rm -rf /var/lib/apt/lists/*

# install rclone
ARG RCLONE_VERSION=v1.54.1
RUN cd /tmp \
  && curl -O https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-amd64.zip \
  && unzip /tmp/rclone-${RCLONE_VERSION}-linux-amd64.zip \
  && mv /tmp/rclone-*-linux-amd64/rclone /usr/bin \
  && rm -r /tmp/rclone*

COPY --from=gobuild /build/s3driver /s3driver
ENTRYPOINT ["/s3driver"]
