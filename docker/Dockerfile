# Test image for YuE2 Studio e2e (Linux arm64, headless via Xvfb). Built once, not per run:
#   docker build -t yue2-studio-test:3.44.3 /Users/fabiobiola/Developer/neokree/yue-studio/docker
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zip rsync file \
      clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev \
      xvfb xauth libegl1 libgl1 libgles2 libgl1-mesa-dri fonts-dejavu-core \
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
      gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    && rm -rf /var/lib/apt/lists/*

# uv: pinned, sha256 verified (linux aarch64 asset of the astral-sh/uv release)
ARG UV_VERSION=0.13.7
ARG UV_SHA256=71279f8d3c67241e807b9d8db872d1bf541579fb9f08b7d1eb1682196d1e57dc
RUN curl -fsSL -o /tmp/uv.tgz https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-aarch64-unknown-linux-gnu.tar.gz \
    && echo "${UV_SHA256}  /tmp/uv.tgz" | sha256sum -c - \
    && tar -xzf /tmp/uv.tgz -C /tmp \
    && install -m 0755 /tmp/uv-aarch64-unknown-linux-gnu/uv /usr/local/bin/uv \
    && rm -rf /tmp/uv.tgz /tmp/uv-aarch64-unknown-linux-gnu \
    && uv --version

# Flutter: no Linux arm64 tarball, so clone the tag
ARG FLUTTER_VERSION=3.44.3
ENV FLUTTER_ROOT=/opt/flutter
ENV PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}
ENV PUB_CACHE=/pub-cache
ENV FLUTTER_SUPPRESS_ANALYTICS=true CI=true
RUN git clone --depth 1 -b ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter \
    && git config --global --add safe.directory '*' \
    && flutter config --no-analytics --enable-linux-desktop \
    && flutter precache --linux \
    && flutter --version

WORKDIR /work
