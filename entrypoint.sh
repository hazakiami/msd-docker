#!/bin/sh
# msd 容器入口脚本（原版 msd，非 lite）
#
# 用法一（推荐）：用环境变量控制，脚本自动渲染 XML 配置
#   docker run -d --network host -e MSD_PORT=7088 -e MSD_IFACE=eth0 msd:latest
#
# 用法二：挂载自己的配置文件
#   docker run -d --network host -v /my/msd.conf:/etc/msd/msd.conf:ro \
#     msd:latest -c /etc/msd/msd.conf
#
# 用法三：直接透传 msd 原生参数
#   docker run -d --network host msd:latest -c /path/conf
set -e

BIN="/usr/local/bin/msd"
TPL="/etc/msd/msd.conf.template"
CONF="/etc/msd/msd.conf"
CHAN_TPL="/etc/msd/msd_channels.conf.template"
CHAN_CONF="/etc/msd/msd_channels.conf"
log() { echo "[msd] $*"; }

# ---- 参数以 - 开头 => 直接透传给 msd ----
case "$1" in
  -*)
    log "透传原始参数: $*"
    exec "$BIN" "$@"
    ;;
esac

# ---- 频道列表文件：用户挂载了就用用户的，否则从模板复制一份 ----
if [ -f "$CHAN_CONF" ]; then
    log "使用已有频道列表: $CHAN_CONF"
elif [ -f "$CHAN_TPL" ]; then
    cp -f "$CHAN_TPL" "$CHAN_CONF"
    log "初始化频道列表: $CHAN_CONF（示例内容，请按需覆盖）"
fi

# ---- 若配置文件已存在（用户挂载），则直接使用 ----
if [ -f "$CONF" ] && [ ! -f "${CONF}.generated" ]; then
    log "使用已有配置文件: $CONF"
else
    log "根据环境变量生成配置..."
    # 从环境变量取值，带默认值
    : "${MSD_PORT:=7088}"
    : "${MSD_IFACE:=eth0}"
    : "${MSD_LOG_LEVEL:=6}"
    : "${MSD_THREADS:=1}"
    : "${MSD_PRECACHE:=4096}"
    : "${MSD_RINGBUF:=32768}"
    : "${MSD_CONGESTION:=htcp}"
    : "${MSD_MPEG2TS:=no}"
    : "${MSD_ZEROCOPY:=no}"
    : "${MSD_STREAM_PROXY:=yes}"

    sed -e "s|__MSD_PORT__|${MSD_PORT}|g" \
        -e "s|__MSD_IFACE__|${MSD_IFACE}|g" \
        -e "s|__MSD_LOG_LEVEL__|${MSD_LOG_LEVEL}|g" \
        -e "s|__MSD_THREADS__|${MSD_THREADS}|g" \
        -e "s|__MSD_PRECACHE__|${MSD_PRECACHE}|g" \
        -e "s|__MSD_RINGBUF__|${MSD_RINGBUF}|g" \
        -e "s|__MSD_CONGESTION__|${MSD_CONGESTION}|g" \
        -e "s|__MSD_MPEG2TS__|${MSD_MPEG2TS}|g" \
        -e "s|__MSD_ZEROCOPY__|${MSD_ZEROCOPY}|g" \
        -e "s|__MSD_STREAM_PROXY__|${MSD_STREAM_PROXY}|g" \
        "$TPL" > "$CONF"
    touch "${CONF}.generated"

    log "监听端口   : ${MSD_PORT}"
    log "组播网卡   : ${MSD_IFACE}"
    log "线程数     : ${MSD_THREADS}"
    log "预缓存     : ${MSD_PRECACHE} KB"
    log "环形缓冲   : ${MSD_RINGBUF} KB"
    log "拥塞算法   : ${MSD_CONGESTION}"
    log "MPEG2TS 分析器 : ${MSD_MPEG2TS}"
    log "零拷贝发送 : ${MSD_ZEROCOPY}"
fi

# 校验网卡是否存在，提前给出明确提示而不是静默失败
if [ -r /proc/net/dev ]; then
    if ! grep -qE "^\s*${MSD_IFACE}:" /proc/net/dev; then
        log "⚠️  警告: 网卡 '${MSD_IFACE}' 不存在！请用 -e MSD_IFACE=实际网卡名 指定。"
        log "    当前可用网卡: $(awk -F: '/:/{gsub(/ /,"",$1); printf "%s ", $1}' /proc/net/dev)"
    fi
fi

# 校验端口占用（host 网络模式下常见问题）
if [ -r /proc/net/tcp ]; then
    HEXPORT=$(printf '%04X' "${MSD_PORT}" 2>/dev/null || echo "")
    if [ -n "$HEXPORT" ] && awk '{print $2}' /proc/net/tcp 2>/dev/null | grep -qi ":${HEXPORT}$"; then
        log "⚠️  警告: TCP 端口 ${MSD_PORT} 已被占用，msd 可能启动失败。"
    fi
fi

log "启动命令: ${BIN} -c ${CONF}"
exec "$BIN" -c "$CONF"
