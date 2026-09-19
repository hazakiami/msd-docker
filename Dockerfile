# msd — 多阶段构建，静态链接
# 原版 msd（Multi stream daemon），比 msd_lite 功能更全：
#   支持频道列表(/channel/)、MPEG2TS 分析器、零拷贝发送、HTTP/TCP 源转发
FROM ubuntu:latest AS builder

ARG MSD_BRANCH=master

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl tar gzip \
        build-essential cmake libc6-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# ---- 下载 msd 主仓库 ----
RUN set -eux; \
    for url in \
      "https://ghfast.top/https://github.com/rozhuk-im/msd/archive/refs/heads/${MSD_BRANCH}.tar.gz" \
      "https://gh-proxy.com/https://github.com/rozhuk-im/msd/archive/refs/heads/${MSD_BRANCH}.tar.gz" \
      "https://codeload.github.com/rozhuk-im/msd/tar.gz/refs/heads/${MSD_BRANCH}" \
    ; do \
      echo "trying $url"; \
      if curl -4 -fsSL --connect-timeout 15 "$url" -o /tmp/msd.tar.gz && tar tzf /tmp/msd.tar.gz >/dev/null 2>&1; then \
        echo "downloaded: $url"; break; \
      fi; \
    done; \
    tar xzf /tmp/msd.tar.gz --strip-components=1; \
    rm -f /tmp/msd.tar.gz; \
    test -f CMakeLists.txt

# ---- liblcb 是 git submodule ----
# tarball 不含子模块内容，必须单独获取，否则 CMake 报：
#   include could not find requested file: src/liblcb/CMakeLists.txt
RUN set -eux; \
    rm -rf src/liblcb; mkdir -p src/liblcb; \
    for url in \
      "https://ghfast.top/https://github.com/rozhuk-im/liblcb/archive/refs/heads/master.tar.gz" \
      "https://gh-proxy.com/https://github.com/rozhuk-im/liblcb/archive/refs/heads/master.tar.gz" \
      "https://codeload.github.com/rozhuk-im/liblcb/tar.gz/refs/heads/master" \
    ; do \
      echo "trying liblcb: $url"; \
      if curl -4 -fsSL --connect-timeout 15 "$url" -o /tmp/liblcb.tar.gz && tar tzf /tmp/liblcb.tar.gz >/dev/null 2>&1; then \
        tar xzf /tmp/liblcb.tar.gz -C src/liblcb --strip-components=1; \
        echo "liblcb ok"; break; \
      fi; \
    done; \
    rm -f /tmp/liblcb.tar.gz; \
    test -f src/liblcb/CMakeLists.txt

# ---- 静态编译 ----
# CMakeLists 内部 try_linker_flag 会追加 -pie / -z relro 等加固参数，与 -static 冲突，
# 因此显式关闭 PIE。
RUN set -eux; \
    mkdir -p build && cd build; \
    cmake .. \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_EXE_LINKER_FLAGS="-static -no-pie" \
      -DCMAKE_C_FLAGS="-static -no-pie -fno-pie" \
    && make -j"$(nproc)" \
    && strip --strip-all src/msd \
    && mkdir -p /out \
    && cp -f src/msd /out/msd \
    && ls -l /out/msd

# ============================================================
FROM alpine:latest

LABEL org.opencontainers.image.title="msd" \
      org.opencontainers.image.description="Multi stream daemon — IPTV multicast to HTTP relay (full version)" \
      org.opencontainers.image.source="https://github.com/rozhuk-im/msd" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

RUN set -eux; \
    addgroup -S msd; \
    adduser -S -G msd -H -s /sbin/nologin msd; \
    mkdir -p /etc/msd

COPY --from=builder /out/msd /usr/local/bin/msd

ENV MSD_PORT=7088 \
    MSD_IFACE=eth0 \
    MSD_LOG_LEVEL=6 \
    MSD_PRECACHE=4096 \
    MSD_RINGBUF=32768 \
    MSD_THREADS=1 \
    MSD_CONGESTION=htcp \
    MSD_MPEG2TS=no \
    MSD_ZEROCOPY=no \
    MSD_STREAM_PROXY=yes

COPY entrypoint.sh /entrypoint.sh
COPY msd.conf.template /etc/msd/msd.conf.template
COPY msd_channels.conf.template /etc/msd/msd_channels.conf.template
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${MSD_PORT}/stat" || exit 1

EXPOSE 7088/tcp

ENTRYPOINT ["/entrypoint.sh"]
