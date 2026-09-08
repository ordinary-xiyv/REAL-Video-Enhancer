# REAL-Video-Enhancer 安装文档（仅 NCNN 后端）

本文档记录从源码安装 REAL-Video-Enhancer 的完整流程，**只安装 NCNN 后端**
（基于 Vulkan，不依赖 NVIDIA CUDA / TensorRT，适用于任何支持 Vulkan 1.3 的 GPU）。

整体结构说明：

- **GUI 前端**：用系统 Python（3.10/3.11/3.12）+ 项目根目录的 `venv` 运行。
- **推理后端**：项目首次启动时会自动下载一个**便携版 Python 3.12.9** 到
  `python/python/`，所有推理依赖（ncnn 等）都安装在这个便携 Python 里，
  与系统 Python 完全隔离。
- 因为仓库根目录自带 `backend/` 目录，程序进入「本地后端模式」，
  所有组件（便携 Python、ffmpeg、模型）都会装在仓库目录内，
  不会写入 `~/.local/share`。

---

## 1. 环境要求

| 项目 | 要求 |
|--|--|
| 操作系统 | Linux（Ubuntu 22.04+ 推荐）/ Windows 10/11 64bit / macOS 14+ |
| GPU | 支持 Vulkan 1.3 的设备（核显亦可，无需 N 卡） |
| 显存 | ≥ 4 GB |
| 内存 | ≥ 16 GB |
| 磁盘 | ≥ 1 GB 空闲 |
| 系统 Python | 3.10 / 3.11 / 3.12（仅用于 GUI 和构建） |

Linux 下 GUI（Qt）运行所需的系统库：

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip git \
    libxcb-cursor0 libegl1 libxkbcommon0 libglib2.0-0
# 建议同时安装 vulkan 工具用于验证 GPU
sudo apt install -y vulkan-tools
```

## 2. 克隆代码

```bash
# 开发版（nightly）
git clone --recurse-submodules https://github.com/TNTwise/REAL-Video-Enhancer
cd REAL-Video-Enhancer

# 或稳定版
git clone --recurse-submodules https://github.com/TNTwise/REAL-Video-Enhancer --branch 2.4.1
cd REAL-Video-Enhancer
```

## 3. 构建 GUI 前端

`build.py` 会自动完成：创建 `venv` → 安装 `requirements.txt` →
用 PySide6 的 `uic`/`rcc` 生成 `mainwindow.py` 和 `resources_rc.py`。

```bash
python3 build.py --build gui
```

如需打包成独立可执行文件（可选，仅 NCNN 也走同样流程）：

```bash
# Linux 推荐 cx_freeze；Windows/Mac 推荐 pyinstaller
python3 build.py --build cx_freeze --copy_backend
```

## 4. 准备运行时组件（便携 Python + ffmpeg）

首次运行 GUI 时会自动下载以下组件；也可以手动执行（无 GUI 的纯命令行
部署时很有用）。

### 4.1 下载便携版 Python 3.12.9（后端推理专用）

```bash
mkdir -p python
curl -L -o python/python.tar.gz \
  "https://github.com/TNTwise/REAL-Video-Enhancer-models/releases/download/models/cpython-3.12.9+20250317-x86_64-unknown-linux-gnu-install_only.tar.gz"
tar -xzf python/python.tar.gz -C python/
rm python/python.tar.gz

# 验证
./python/python/bin/python3 --version   # 应输出 Python 3.12.9
```

> 其他平台的下载链接规律见 `src/DownloadDeps.py` 中 `Python.get_download_link()`：
> Windows 为 `x86_64-pc-windows-msvc-install_only.tar.gz`，
> macOS 为 `x86_64/aarch64-apple-darwin-install_only.tar.gz`，
> Linux ARM64 为 `aarch64-unknown-linux-gnu-install_only.tar.gz`。

### 4.2 下载 ffmpeg

```bash
mkdir -p bin
curl -L -o bin/ffmpeg \
  "https://github.com/TNTwise/real-video-enhancer-models/releases/download/models/ffmpeg"
chmod +x bin/ffmpeg
```

> Windows 下载 `ffmpeg.exe`，macOS 下载 `ffmpeg-macos-bin`（Intel）或
> `ffmpeg-macos-arm`（Apple Silicon），Linux ARM64 下载 `ffmpeg-linux-arm64`。

## 5. 安装 NCNN 后端依赖（核心步骤）

### 方式 A：GUI 内安装（推荐普通用户）

启动 GUI（见第 7 节），进入 **Download** 标签页，点击 **Download NCNN**
按钮即可，装完重启应用。

### 方式 B：命令行安装（与 GUI 完全等价）

GUI 内部实际执行的 pip 命令（见 `src/DownloadDeps.py` 的
`downloadPythonDeps("ncnn")`），可手动复现：

```bash
./python/python/bin/python3 -m pip install --no-warn-script-location --isolated \
    testresources==2.0.1 \
    requests==2.32.3 \
    opencv-python-headless==4.11.0.86 \
    pypresence==4.3.0 \
    scenedetect==0.6.5.2 \
    numpy==2.2.2 \
    sympy \
    tqdm==4.67.1 \
    typing_extensions==4.12.2 \
    packaging==24.2 \
    mpmath==1.3.0 \
    pillow==11.1.0 \
    rife-ncnn-vulkan-python-tntwise==1.4.5 \
    upscale_ncnn_py==1.2.0 \
    ncnn==1.0.20250916

# 清理 pip 缓存（GUI 也会做这一步）
./python/python/bin/python3 -m pip cache purge
```

其中 NCNN 专属的三个包：

| 包 | 作用 |
|--|--|
| `ncnn==1.0.20250916` | NCNN Vulkan 推理框架的 Python 绑定 |
| `rife-ncnn-vulkan-python-tntwise==1.4.5` | RIFE 补帧模型的 NCNN 实现 |
| `upscale_ncnn_py==1.2.0` | 超分/修复模型的 NCNN 实现 |

> 注意：**不要**安装 `torch` / `torchvision` / `tensorrt`，NCNN 后端完全不需要它们。
> 后端检测逻辑（`backend/src/utils/BackendDetect.py`）只要
> `rife_ncnn_vulkan_python` 和 `ncnn` 能导入即判定 NCNN 可用。

## 6. 验证安装

```bash
# 1) 确认 Vulkan 设备被系统识别
vulkaninfo --summary

# 2) 确认后端版本
./python/python/bin/python3 backend/rve-backend.py --version
# 输出示例: 2.4.1-dev16

# 3) 确认 NCNN 后端可用（关键验证）
./python/python/bin/python3 backend/rve-backend.py --list_backends
# 输出示例:
#   NCNN Version: 20220729
#   NCNN GPU 0: Tesla T4
#   ...
#   Available Backends: ['ncnn']
```

`--list_backends` 输出 `['ncnn']` 即表示安装成功。

## 7. 运行

### GUI 方式

```bash
python3 build.py --run
# 或等价地：
venv/bin/python3 REAL-Video-Enhancer.py
```

模型在 GUI 的 **Download** 标签页下载，存到 `models/` 目录。
NCNN 专用模型名字带 `.ncnn` 后缀（如 `rife-v4.26`、
`2x_AniSD_G6i2b_SPAN_190K.ncnn`、`1xDeH264_RTMoSR.ncnn`）；
`realesr-*`、`2x_AnimeJaNai*` 等目录模型同样可被 NCNN 后端使用。

### 命令行（CLI）方式

超分（以 2 倍动画模型为例）：

```bash
./python/python/bin/python3 backend/rve-backend.py \
    -i input.mp4 -o output.mp4 \
    --backend ncnn \
    --upscale_model models/2x_AnimeJaNai_HD_V3_Sharp1_Compact_430k \
    --ffmpeg_path bin/ffmpeg
```

补帧（以 RIFE 4.26 为例，帧率 ×2）：

```bash
./python/python/bin/python3 backend/rve-backend.py \
    -i input.mp4 -o output_2x_fps.mp4 \
    --backend ncnn \
    --interpolate_model models/rife-v4.26 \
    --interpolate_factor 2 \
    --ffmpeg_path bin/ffmpeg
```

常用参数：`-b ncnn` 指定后端；`--precision auto`（默认）；`--crf 18`
控制输出质量；`--overwrite` 允许覆盖输出文件；完整参数见
`./python/python/bin/python3 backend/rve-backend.py --help`。

仓库根目录还提供了 `pipeline.sh`，封装了「去水印 → 超分」的两段式
NCNN 处理流程，可直接参考其调用方式。

## 7.1 API 服务（编程调用）

后端附带一个 HTTP API 服务 `backend/rve-api.py`（纯标准库实现，无额外依赖），
适合被其他程序/脚本调用。以子进程方式包装 CLI，异步任务模型：提交后立即返回
`job_id`，客户端轮询状态。

启动：

```bash
./python/python/bin/python3 backend/rve-api.py --host 0.0.0.0 --port 8877
# 默认监听 127.0.0.1:8877（仅本机）；--host 0.0.0.0 对外开放
```

端点：

| 方法 | 路径 | 说明 |
|--|--|--|
| GET | `/health` | 服务状态（排队/运行中任务数） |
| GET | `/models` | 可用模型列表 + 别名（anime/real/dncnn/deh264） |
| POST | `/jobs` | 提交任务，返回 `{"job_id": ...}` |
| GET | `/jobs` | 任务列表 |
| GET | `/jobs/{id}` | 任务详情（status/progress/帧进度/日志尾部） |
| DELETE | `/jobs/{id}` | 取消任务 |

示例（超分）：

```bash
# 提交任务
curl -X POST http://127.0.0.1:8877/jobs \
  -H 'Content-Type: application/json' \
  -d '{"input":"/data/in.mp4","output":"/data/out.mp4","task":"upscale","model":"real"}'
# => {"job_id": "ab12cd34ef56", "status": "queued"}

# 轮询状态
curl http://127.0.0.1:8877/jobs/ab12cd34ef56
# => {"status": "running", "progress": 53.7, "current_frame": 65, "total_frames": 121, ...}
#    status: queued | running | done | failed | cancelled

# 取消
curl -X DELETE http://127.0.0.1:8877/jobs/ab12cd34ef56
```

示例（DnCNN 降噪）：

```bash
curl -X POST http://127.0.0.1:8877/jobs \
  -H 'Content-Type: application/json' \
  -d '{"input":"/data/in.mp4","output":"/data/dn.mp4","task":"denoise","model":"dncnn"}'
```

超分与降噪可叠加（`task=upscale` 时加 `denoise_model` 字段）；`model` 支持别名、
`models/` 下目录名或绝对路径；可选字段 `crf`、`encoder`。
任务串行执行（GPU 推理同时只跑一个），多余任务自动排队。

## 8. 常见问题

| 问题 | 解决办法 |
|--|--|
| Vulkan 报错 / 崩溃 | 多为显存不足（OOM），常见于弱核显或过老 GPU，换更小的模型或降低输入分辨率 |
| `--list_backends` 输出为空 | 重新执行第 5 节的 pip 安装命令，确认三个 NCNN 包都装进了 `python/python/` 这个便携环境而不是系统 Python |
| GUI 启动报 `libxcb-cursor` 相关错误 | `sudo apt install libxcb-cursor0` 后重试 |
| 检测不到已安装的后端 | 删除 `python/` 目录后重新执行第 4、5 节 |
| Windows 上需要 vcredist | 安装 [VC_redist.x64.exe](https://aka.ms/vs/17/release/vc_redist.x64.exe) |
