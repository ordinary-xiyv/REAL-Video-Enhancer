#!/bin/bash
# destroy_watermark.sh — 暗水印破坏二阶段预处理（参数参照《Hwater处理》文档 Grid A 配置）
#   Stage 1: setsar + 降噪滤镜(可选) + 动态噪声扰动 + H.264 重编码（crf 23, veryslow）
#   Stage 2: 微重采样（bicubic 缩小 → lanczos 放回原尺寸）+ 二次重编码（crf 23, veryslow）
# 用法: ./destroy_watermark.sh <输入视频> [输出视频] [pass2缩放比例=0.975] [平移像素=0] [降噪滤镜=default]
#   平移像素: 可选增强项（文档原方案不含）。>0 时在 Stage2 缩放后做居中裁剪偏移，
#             实测可将水印相关性残留从 ~40% 降至 0，代价是边缘裁剪几个像素。
#   降噪滤镜: default = hqdn3d=0.8:0.8:3:3；none = 不降噪（如降噪交给后端 DnCNN）；
#             其他字符串作为自定义 ffmpeg 滤镜使用，如 'hqdn3d=3:3:6:6'
set -e
cd "$(dirname "$0")"
FF=bin/ffmpeg

IN="$1"
OUT="${2:-output_clean.mp4}"
SCALE="${3:-0.975}"
SHIFT="${4:-0}"
DENOISE_VF="${5:-default}"
[ "$DENOISE_VF" = "default" ] && DENOISE_VF="hqdn3d=0.8:0.8:3:3"

if [ -z "$IN" ]; then
    echo "用法: $0 <输入视频> [输出视频=output_clean.mp4] [pass2缩放比例=0.975] [平移像素=0] [降噪滤镜=default]"
    exit 1
fi

# Stage2 微重采样滤镜
if [ "$SHIFT" -gt 0 ] 2>/dev/null; then
    # 平移模式：裁剪后需显式按原分辨率放大，先读取输入尺寸
    read W H <<< $($FF -i "$IN" 2>&1 | grep -oP '\d{3,4}x\d{3,4}' | head -1 | tr 'x' ' ')
    [ -z "$W" ] && { echo "错误: 无法读取输入视频分辨率"; exit 1; }
    VF2="scale='trunc(iw*${SCALE}/2)*2':'trunc(ih*${SCALE}/2)*2':flags=bicubic,crop=iw-$((SHIFT*2)):ih-$((SHIFT*2)):${SHIFT}:${SHIFT},scale=${W}:${H}:flags=lanczos,setsar=1"
else
    # 比例表达式设计，自动适配任意输入分辨率
    VF2="scale='trunc(iw*${SCALE}/2)*2':'trunc(ih*${SCALE}/2)*2':flags=bicubic,scale='ceil(iw/${SCALE}/2)*2':'ceil(ih/${SCALE}/2)*2':flags=lanczos,setsar=1"
fi

TMP1=$(mktemp --suffix=.mp4)
trap "rm -f '$TMP1'" EXIT

# Stage1 滤镜链：setsar → 降噪(可选) → 动态噪声
VF1="setsar=1"
if [ "$DENOISE_VF" != "none" ]; then
    VF1="$VF1,$DENOISE_VF"
fi
VF1="$VF1,noise=alls=2:allf=t+u"

echo "[Stage 1] $VF1 + 重编码(crf 23, veryslow) ..."
$FF -hide_banner -loglevel error -y -i "$IN" \
    -vf "$VF1" \
    -c:v libx264 -preset veryslow -crf 23 -pix_fmt yuv420p \
    -c:a aac -b:a 128k -ar 44100 \
    -map_metadata -1 -movflags +faststart \
    "$TMP1"

echo "[Stage 2] 微重采样 (${SCALE}, bicubic→lanczos)$([ "$SHIFT" -gt 0 ] 2>/dev/null && echo " + 平移 ±${SHIFT}px") + 二次重编码(crf 23, veryslow) ..."
$FF -hide_banner -loglevel error -y -i "$TMP1" \
    -vf "$VF2" \
    -c:v libx264 -preset veryslow -crf 23 -pix_fmt yuv420p \
    -c:a copy \
    -map_metadata -1 -movflags +faststart \
    "$OUT"

echo "完成: $OUT"
