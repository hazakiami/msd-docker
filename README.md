# msd Docker 镜像（完整版，非 lite）

把 **原版 msd**（Multi stream daemon，IPTV 组播转 HTTP 工具）编译并打包成 Docker 镜像。

| 项目 | 值 |
|---|---|
| msd 版本 | **3.2.0** |
| liblcb 版本 | master（git submodule） |
| 镜像标签 | `msd:3.2.0` / `msd:latest` |
| 镜像大小 | **14.3 MB**（导出 tar 4.3 MB） |
| 基础镜像 | ubuntu:24.04（构建） / alpine:3.21（运行） |
| 链接方式 | **静态链接**（无动态库依赖） |
| 二进制大小 | 1.37 MB（strip 后） |
| 架构 | linux/amd64 |

## msd / msd_lite / udpxy 三者对比

| 特性 | udpxy | msd_lite | **msd（本镜像）** |
|---|---|---|---|
| 构建方式 | Makefile | CMake | CMake |
| 配置方式 | 命令行参数 | XML | **XML（分层，更复杂）** |
| 默认端口 | 4022 | 7088 | **7088** |
| 频道列表 | ❌ | ❌ | ✅ `/channel/<name>` |
| MPEG2-TS 分析器 | ❌ | ❌ | ✅ **按 PID 过滤** |
| 零拷贝发送 | ❌ | ❌ | ✅ `fZeroCopyOnSend` |
| HTTP 源转发 | ❌ | 部分 | ✅ `/http/host:port/path` |
| 透明代理 | ❌ | ❌ | ✅ |
| 线程池 | ❌ | 支持 | **支持 + CPU 绑定** |
| 环形缓冲存储 | 内存 | 共享内存 | **共享内存（`shm`）** |
| 资源占用 | 高 | 低 | 中等 |

> **选择建议**：只做简单的组播转 HTTP → `msd_lite`；需要频道列表、PID 过滤、零拷贝、HTTP 源转发 → `msd`；需要兼容老配置 → `udpxy`。

## 文件说明

| 文件 | 用途 |
|---|---|
| `Dockerfile` | 多阶段构建（下载源码 → 静态编译 → 精简运行镜像） |
| `entrypoint.sh` | 入口脚本，用环境变量渲染 XML 配置 |
| `msd.conf.template` | 主配置模板 |
| `msd_channels.conf.template` | 频道列表模板 |
| `README.md` | 本文档 |

## 快速开始

### 方式一：环境变量（推荐）

```bash
docker run -d \
  --name msd \
  --network host \
  -e MSD_PORT=7088 \
  -e MSD_IFACE=eth0 \
  --restart unless-stopped \
  msd:3.2.0
```

### 方式二：挂载自己的配置

```bash
docker run -d --name msd --network host \
  -v /my/msd.conf:/etc/msd/msd.conf:ro \
  -v /my/msd_channels.conf:/etc/msd/msd_channels.conf:ro \
  msd:3.2.0
```

### 方式三：透传原生参数

```bash
docker run -d --name msd --network host \
  msd:3.2.0 -c /etc/msd/msd.conf
```

## 播放地址

```
UDP 组播   : http://<服务器IP>:7088/udp/<组播地址>:<端口>
RTP 组播   : http://<服务器IP>:7088/rtp/<组播地址>:<端口>
HTTP 源    : http://<服务器IP>:7088/http/<主机>:<端口>/<路径>
预定义频道 : http://<服务器IP>:7088/channel/<频道名>
统计页     : http://<服务器IP>:7088/stat
```

## 环境变量

| 变量 | 默认值 | 单位 | 说明 |
|---|---|---|---|
| `MSD_PORT` | `7088` | — | HTTP 监听端口 |
| `MSD_IFACE` | `eth0` | — | **接收组播的网卡名** |
| `MSD_LOG_LEVEL` | `6` | — | 0=emerg ~ 7=debug |
| `MSD_THREADS` | `1` | — | 线程池大小，0=自动 |
| `MSD_PRECACHE` | `4096` | **KB** | 预缓存大小 |
| `MSD_RINGBUF` | `32768` | **KB** | 环形缓冲区，须 ≥ precache |
| `MSD_CONGESTION` | `htcp` | — | TCP 拥塞控制算法 |
| `MSD_MPEG2TS` | `no` | — | **是否启用 MPEG2-TS 分析器** |
| `MSD_ZEROCOPY` | `no` | — | 是否启用零拷贝发送 |
| `MSD_STREAM_PROXY` | `yes` | — | 是否启用 `/udp/`、`/http/` 自动代理 |

> ⚠️ **单位陷阱**：`precache` / `ringBufSize` 单位是 **KB**（程序内部 ×1024），
> 而 `sndBuf` / `rcvBuf` 等套接字缓冲单位是**字节**。混淆会导致参数被错误钳制。

## 重要注意事项

### 1. 必须使用 host 网络

msd 依赖 **IGMP 组播**接收 IPTV 流，Docker bridge 网络无法正常收发组播。
务必用 `--network host`。

### 2. 网卡名必须写对

`MSD_IFACE` 要填**实际接收 IPTV 组播的物理网卡**（`ip a` 查看），如 `eth0`、`ens33`。
源码用 `if_nametoindex()` 转换，**写 IP 地址会导致组播加入失败**。
入口脚本会检查网卡是否存在，不存在时打印警告并列出可用网卡。

### 3. ⚠️ `includeFile` 路径不能加 `-` 前缀（实测踩坑）

源码中频道列表的加载逻辑是：

```c
error = read_file((const char*)ptm, tm, 0, 0, CFG_FILE_MAX_SIZE, ...);
// read_file() 内部：fd = open(filename, O_RDONLY);   ← 路径原样使用
```

`read_file()` **不做任何前缀解析**，直接把路径交给 `open()`。
若写成上游示例里的 `-/root/msd/msd_channels.conf`，会被当成**字面文件名**，报：

```
Load channels: FAIL from "-/etc/msd/msd_channels.conf". Error 2: No such file or directory
```

✅ **正确写法**：`<includeFile>/etc/msd/msd_channels.conf</includeFile>`

### 4. ⚠️ MPEG2-TS 分析器要求 PAT/PMT 的 CRC 正确（实测踩坑）

启用 `MSD_MPEG2TS=yes` 后，分析器只转发**在 PAT/PMT 中注册过的 PID**，
其余一律计入 `unknown_pid_count` 并丢弃（除非 filterPIDList 里显式保留 `unknown`）。

关键点：**PMT 的 CRC32 必须正确，否则分析器解析失败，ES 的 PID 根本不会被注册**，
表现为「HTTP 200 正常、body 恒为 0 字节」。

实测对比（合成流，7.97 Mbps，25 秒）：

| 场景 | 接收字节 | 说明 |
|---|---|---|
| 分析器关闭，任意流 | 12,201,984 | 全部透传 |
| 分析器开启，PMT **CRC 错误** | ~65,536 | ES PID 未注册，被当 unknown 丢弃 |
| 分析器开启，PMT **CRC 正确** | 12,140,544 | 正常转发 ✅ |

CRC 正确的场景下 PID 分布：`{256: 63309, 0: 1268}` ——
**PMT（PID 4096）被分析器主动过滤掉了**，这是设计行为（PSI 表不再需要转发给客户端）。

> **实操建议**：接真实 IPTV 源时 PAT/PMT 的 CRC 天然正确，无需担心。
> 只有自己构造测试流时才容易踩这个坑 —— 此时要么写对 CRC，要么先设 `MSD_MPEG2TS=no`。

### 5. 测试时码率必须足够高

与 msd_lite 同样的机制：`str_hub_send_to_client()` 中若
`snd_block_min_size > 可用数据量` 就**直接返回不发送**。
低码率测试包会出现「HTTP 200、body 为 0」的现象。
✅ **正确测法**：模拟真实 IPTV 码率（约 8 Mbps），实测可稳定接收 12 MB/12 秒。

### 6. 组播源需先通

msd 只做转发，前提是服务器本身能收到上游 IPTV 组播。

## 常用运维命令

```bash
docker logs -f msd                                          # 查看日志
docker inspect msd --format '{{.State.Health.Status}}'      # 健康状态
curl -s http://127.0.0.1:7088/stat                          # 统计信息
ss -tln | grep 7088                                         # 监听检查
docker restart msd                                          # 重启
```

## 镜像传输

```bash
docker save msd:3.2.0 -o msd-3.2.0.tar   # 源机导出
docker load -i msd-3.2.0.tar             # 目标机导入
```

## 已知事项

- **liblcb 是 git submodule**：源码 tarball 不包含子模块内容，直接构建会报
  `include could not find requested file: src/liblcb/CMakeLists.txt`。
  Dockerfile 已单独下载 liblcb 并填入 `src/liblcb/`。
- **静态链接的 glibc 警告**：构建时会出现
  `Using 'getpwuid_r' in statically linked applications requires at runtime the shared libraries...`。
  这是 glibc 静态链接的固有限制，仅在调用 `-u/-g`（切换用户）时受影响；
  容器内以 root 运行不需要该功能，实测运行正常。
- **CMake 与本项目编译参数**：CMakeLists 内部 `try_linker_flag` 会追加 `-pie` 等加固参数，
  与 `-static` 冲突，因此显式传入 `-no-pie`：
  ```bash
  cmake .. -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_EXE_LINKER_FLAGS="-static -no-pie" \
    -DCMAKE_C_FLAGS="-static -no-pie -fno-pie"
  ```

## 构建命令（可复现）

```bash
docker build -t msd:3.2.0 -t msd:latest .
```

源码下载使用代理（`ghfast.top` → `gh-proxy.com` → `codeload.github.com` 三级 fallback），
网络受限环境也能构建成功。

## 验证记录

| 检查项 | 结果 |
|---|---|
| 容器启动 | ✅ `Up (healthy)` |
| 健康检查 `/stat` | ✅ HTTP 200 |
| 频道列表加载 | ✅ `cctv1.ts` / `cctv2.ts` 已创建 |
| 不存在频道 | ✅ HTTP 404 |
| 端到端转发（分析器关闭） | ✅ 12.20 MB / 25 秒 |
| 端到端转发（分析器开启，CRC 正确） | ✅ 12.14 MB / 25 秒 |
| TS 流合法性 | ✅ 同步字节 0x47 命中率 100% |
