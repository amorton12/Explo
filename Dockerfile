# ARM build? docker build --no-cache --build-arg S6_OVERLAY_ARCH=aarch64 -t explo-s6-test .

FROM --platform=$BUILDPLATFORM node:20-alpine AS ui-builder
WORKDIR /app/src/web/frontend
COPY src/web/frontend/package*.json ./
RUN npm ci
COPY src/web/frontend/ ./
RUN npm run build

FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder

# Set the working directory
WORKDIR /app

# Copy the Go source code into the container
COPY ./ .

# Copy the built React frontend into the embed path
COPY --from=ui-builder /app/src/web/dist ./src/web/dist

# Build the Go binary based on the target architecture
ARG TARGETARCH
ARG VERSION=dev
RUN GOOS=linux GOARCH=$TARGETARCH go build -ldflags "-X explo/src/config.Version=${VERSION}" -o explo ./src/main/

FROM python:3.12-alpine

# Install runtime deps: libc compat, ffmpeg, yt-dlp, tzdata, shadow for user management, su-exec for user switching,
# plus xz for extracting the s6 overlay.
RUN apk add --no-cache \
    libc6-compat \
    ffmpeg \
    yt-dlp \
    tzdata \
    xz \
    shadow \
    su-exec 

# Install ytmusicapi in the container
RUN pip install --no-cache-dir ytmusicapi

# Set working directory
WORKDIR /opt/explo/

ARG TARGETARCH
ARG S6_OVERLAY_VERSION=3.2.3.0
ARG S6_OVERLAY_ARCH=x86_64

ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# Install s6-overlay using the documented ADD + tar pattern.
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_OVERLAY_ARCH}.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-${S6_OVERLAY_ARCH}.tar.xz \
    && rm -f /tmp/s6-overlay-noarch.tar.xz /tmp/s6-overlay-${S6_OVERLAY_ARCH}.tar.xz

# Copy entrypoint helper, binary, python helper, and s6 service definitions.
COPY ./docker/start.sh /usr/local/bin/explo-runtime.sh
COPY ./docker/rootfs/ /
COPY --from=builder /app/explo .
COPY src/downloader/youtube_music/search_ytmusic.py .


RUN chmod +x /usr/local/bin/explo-runtime.sh ./explo \
        && find /etc/cont-init.d -type f -exec chmod +x {} + \
        && find /etc/services.d -type f \( -name run -o -name finish \) -exec chmod +x {} + \
        && chmod +x /usr/local/bin/explo-cron-run


ENV WEB_ADDR=":7288"

EXPOSE 7288

ENTRYPOINT ["/init"]