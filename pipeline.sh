#!/bin/bash
# pipeline.sh — 漫剧短视频一条龙处理：破坏暗水印 → 超分增强
#
# 用法: ./pipeline.sh <输入视频> [输出视频] [目标分辨率] [pass2缩放] [平移像素] [模型] [降噪]
#   目标分辨率: auto(默认) | 720 | 1080 | same
#     auto 规则（短边判断）: <720 → 720p；720~1079 → 1080p；>=1080 → 原尺寸增强
#   pass2缩放: 默认 0.975（Stage2 微重采样比例，调小破坏更强）
#   平移像素: 默认 7（0 = 关闭平移扰动，不推荐）
#   模型: anime(默认, AnimeJaNaiV3 2x, 漫剧向) | real(OpenProteus 2x, 真人向)
#         也可直接给 models/ 下的目录名或完整模型路径
#   降噪: ffmpeg(默认, Stage1 用 hqdn3d 滤镜) | dncnn(DnCNN 模型, 后端降噪) | none(不降噪)
#         也可直接给自定义 ffmpeg 滤镜串，如 'hqdn3d=3:3:6:6'
#
# 示例:
#   ./pipeline.sh input.mp4                     # 全自动（漫剧模型）
#   ./pipeline.sh input.mp4 out.mp4 720         # 强制输出 720p
#   ./pipeline.sh input.mp4 out.mp4 720 0.975 7 real   # 真人素材用 OpenProteus
#   ./pipeline.sh input.mp4 out.mp4 720 0.975 7 real dncnn   # 真人素材 + DnCNN 降噪
#   ./pipeline.sh input.mp4 out.mp4 auto 0.95 12       # 加强水印破坏
set -e
cd "$(dirname "$0")"

FF=bin/ffmpeg
BACKEND="./python/python/bin/python3 backend/rve-backend.py"

IN="$1"
OUT="${2:-$(basename "${IN%.*}")_final.mp4}"
TARGET="${3:-auto}"
P2SCALE="${4:-0.975}"
SHIFT="${5:-7}"
MODEL_ARG="${6:-anime}"
DENOISE="${7:-ffmpeg}"

[ -z "$IN" ] && { sed -n '2,19p' "$0"; exit 1; }
[ -f "$IN" ] || { echo "错误: 输入文件不存在: $IN"; exit 1; }

# ---------- 解析超分模型 ----------
case "$MODEL_ARG" in
    anime) UPSCALE_MODEL=models/2x_AnimeJaNai_HD_V3_Sharp1_Compact_430k ;;
    real)  UPSCALE_MODEL=models/2x_OpenProteus_Compact_i2_70K ;;
    *)     UPSCALE_MODEL="$MODEL_ARG" ;;
esac
# 允许只写 models/ 下的目录名
if [ ! -d "$UPSCALE_MODEL" ] && [ -d "models/$UPSCALE_MODEL" ]; then
    UPSCALE_MODEL="models/$UPSCALE_MODEL"
fi
[ -d "$UPSCALE_MODEL" ] || { echo "错误: 模型不存在: $MODEL_ARG"; echo "可用模型:"; ls models/; exit 1; }

# ---------- 解析降噪方式 ----------
# DW_DENOISE 传给 destroy_watermark.sh：default=hqdn3d 默认参数, none=跳过, 其他=自定义滤镜
DNCNN_MODEL=models/dncnn_color_blind.pth.ncnn
RESTORE_ARGS=()
DW_DENOISE="$DENOISE"
case "$DENOISE" in
    ffmpeg|default) DW_DENOISE="default" ;;
    none) ;;
    dncnn)
        [ -d "$DNCNN_MODEL" ] || { echo "错误: DnCNN 模型不存在: $DNCNN_MODEL"; exit 1; }
        RESTORE_ARGS=(--extra_restoration_models "$DNCNN_MODEL")
        DW_DENOISE="none"   # 降噪交给后端，Stage1 不再用 hqdn3d
        ;;
    *) ;;  # 自定义滤镜原样传给 destroy_watermark.sh
esac

# ---------- 读取分辨率，确定目标 ----------
read W H <<< $($FF -i "$IN" 2>&1 | grep -oP '\d{3,4}x\d{3,4}' | head -1 | tr 'x' ' ')
[ -z "$W" ] && { echo "错误: 无法读取输入视频分辨率"; exit 1; }
SHORT=$(( W < H ? W : H ))

if [ "$TARGET" = "auto" ]; then
    if   [ "$SHORT" -ge 1080 ]; then TARGET="same"
    elif [ "$SHORT" -ge 720 ];  then TARGET=1080
    else                             TARGET=720
    fi
fi

echo "========================================"
echo " 输入: $IN (${W}x${H})"
echo " 输出: $OUT"
echo " 目标: $([ "$TARGET" = "same" ] && echo "原尺寸增强" || echo "${TARGET}p")"
echo " 模型: $UPSCALE_MODEL"
echo " 降噪: $DENOISE"
echo " 水印破坏: 缩放=${P2SCALE} 平移=±${SHIFT}px"
echo "========================================"

# ---------- 中间产物（临时目录） ----------
TMPD=$(mktemp -d)
trap "rm -rf '$TMPD'" EXIT

# ---------- 后端调用封装 ----------
# 已知问题: 本环境下后端进程退出时 NCNN/Vulkan 清理阶段段错误 (rc=139)，
# 但此时渲染和封装已全部完成、输出文件完整。故仅容忍 rc=139，其余错误仍中止。
run_backend() {
    local out=""
    local args=("$@")
    local prev=0
    for ((i=0; i<${#args[@]}; i++)); do
        if [ "${args[$i]}" = "-o" ]; then out="${args[$((i+1))]}"; fi
    done
    set +e
    $BACKEND "${args[@]}"
    local rc=$?
    set -e
    if [ $rc -ne 0 ] && [ $rc -ne 139 ]; then
        echo "错误: 后端执行失败 (rc=$rc)"; exit $rc
    fi
    if [ -n "$out" ] && [ ! -s "$out" ]; then
        echo "错误: 后端未生成有效输出: $out"; exit 1
    fi
}

# ---------- Stage 1+2: 破坏暗水印 ----------
echo "[1/2] 破坏暗水印（Stage1 滤波+噪声+重编码 → Stage2 微重采样）..."
./destroy_watermark.sh "$IN" "$TMPD/stage2.mp4" "$P2SCALE" "$SHIFT" "$DW_DENOISE"

# ---------- Stage 3: 超分 ----------
echo "[2/2] 超分增强..."
if [ "$TARGET" = "same" ]; then
    # 原尺寸增强：2x 超分 → lanczos 缩回原尺寸
    # 比 1x 修复模型（1xDeH264_RTMoSR）去压缩噪点更彻底，代价是多一次缩放耗时
    echo "     2x 超分 → 缩回原尺寸 ${W}x${H}"
    run_backend -i "$TMPD/stage2.mp4" -o "$TMPD/stage3_raw.mp4" -b ncnn \
        --upscale_model "$UPSCALE_MODEL" \
        "${RESTORE_ARGS[@]}" \
        --ffmpeg_path $FF
    $FF -hide_banner -loglevel error -y -i "$TMPD/stage3_raw.mp4" \
        -vf "scale=${W}:${H}:flags=lanczos,setsar=1" \
        -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -c:a copy "$OUT"
else
    # 目标宽高：保持原始宽高比，短边拉到 TARGET
    if [ "$W" -ge "$H" ]; then
        TH=$TARGET; TW=$(( TARGET * W / H / 2 * 2 ))
    else
        TW=$TARGET; TH=$(( TARGET * H / W / 2 * 2 ))
    fi
    echo "     2x 超分 → 缩放到 ${TW}x${TH}"
    run_backend -i "$TMPD/stage2.mp4" -o "$TMPD/stage3_raw.mp4" -b ncnn \
        --upscale_model "$UPSCALE_MODEL" \
        "${RESTORE_ARGS[@]}" \
        --ffmpeg_path $FF
    $FF -hide_banner -loglevel error -y -i "$TMPD/stage3_raw.mp4" \
        -vf "scale=${TW}:${TH}:flags=lanczos,setsar=1" \
        -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -c:a copy "$OUT"
fi

echo "========================================"
echo " 完成: $OUT"
$FF -i "$OUT" 2>&1 | grep -E "Duration|Stream" | sed 's/^/ /'
echo "========================================"
