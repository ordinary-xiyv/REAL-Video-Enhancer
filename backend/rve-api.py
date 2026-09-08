#!/usr/bin/env python3
"""
rve-api.py — RVE 后端 HTTP API 服务（NCNN）

以子进程方式包装 rve-backend.py，提供异步任务式 HTTP API：
    POST   /jobs        提交任务（超分/降噪），返回 job_id
    GET    /jobs        列出所有任务
    GET    /jobs/{id}   任务详情（状态/进度/日志尾部）
    DELETE /jobs/{id}   取消任务
    GET    /models      可用模型列表
    GET    /health      服务状态

启动: ./python/python/bin/python3 backend/rve-api.py --host 0.0.0.0 --port 8877
"""

import argparse
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(BACKEND_DIR)
BACKEND_SCRIPT = os.path.join(BACKEND_DIR, "rve-backend.py")

MODEL_ALIASES = {
    "anime": "2x_AnimeJaNai_HD_V3_Sharp1_Compact_430k",
    "real": "2x_OpenProteus_Compact_i2_70K",
    "dncnn": "dncnn_color_blind.pth.ncnn",
    "deh264": "1xDeH264_RTMoSR.ncnn",
}

PROGRESS_RE = re.compile(r"Current Frame:\s*(\d+)")
TOTAL_RE = re.compile(r"Total Frames:\s*(\d+)")
# 后端退出时 NCNN/Vulkan 清理阶段会段错误，shell 报 139，Python subprocess 报 -11，
# 此时渲染和封装已完成、输出文件完整，视为成功
OK_RETURN_CODES = (0, 139, -11)


class Job:
    def __init__(self, job_id: str, params: dict, command: list):
        self.id = job_id
        self.params = params
        self.command = command
        self.status = "queued"  # queued|running|done|failed|cancelled
        self.created_at = time.time()
        self.started_at = None
        self.finished_at = None
        self.total_frames = None
        self.current_frame = 0
        self.error = None
        self.log_tail = deque(maxlen=50)
        self.process = None

    @property
    def progress(self):
        if self.status == "done":
            return 100
        if self.total_frames:
            return min(99, round(self.current_frame / self.total_frames * 100, 1))
        return 0

    def to_dict(self, with_log=False):
        d = {
            "job_id": self.id,
            "status": self.status,
            "progress": self.progress,
            "current_frame": self.current_frame,
            "total_frames": self.total_frames,
            "task": self.params.get("task"),
            "input": self.params.get("input"),
            "output": self.params.get("output"),
            "error": self.error,
            "created_at": self.created_at,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
        }
        if with_log:
            d["command"] = " ".join(self.command)
            d["log_tail"] = list(self.log_tail)
        return d


class JobManager:
    """单工作线程串行消费任务队列（GPU 推理同时只能跑一个）"""

    def __init__(self, models_dir: str, ffmpeg_path: str):
        self.models_dir = models_dir
        self.ffmpeg_path = ffmpeg_path
        self.jobs = {}
        self.lock = threading.Lock()
        self.queue = queue.Queue()
        self.worker = threading.Thread(target=self._work_loop, daemon=True)
        self.worker.start()

    def resolve_model(self, name: str) -> str:
        name = MODEL_ALIASES.get(name, name)
        if os.path.isdir(name):
            return name
        candidate = os.path.join(self.models_dir, name)
        if os.path.isdir(candidate):
            return candidate
        raise ValueError(f"模型不存在: {name}")

    def build_command(self, params: dict) -> list:
        cmd = [
            sys.executable, BACKEND_SCRIPT,
            "-i", params["input"],
            "-o", params["output"],
            "-b", "ncnn",
            "--ffmpeg_path", self.ffmpeg_path,
            "--overwrite",
        ]
        task = params.get("task", "upscale")
        if task == "upscale":
            cmd += ["--upscale_model", self.resolve_model(params.get("model", "anime"))]
            if params.get("denoise_model"):
                cmd += ["--extra_restoration_models",
                        self.resolve_model(params["denoise_model"])]
        elif task == "denoise":
            cmd += ["--extra_restoration_models",
                    self.resolve_model(params.get("model", "dncnn"))]
        else:
            raise ValueError(f"不支持的任务类型: {task} (可选: upscale/denoise)")
        if params.get("crf"):
            cmd += ["--crf", str(params["crf"])]
        if params.get("encoder"):
            cmd += ["--video_encoder_preset", str(params["encoder"])]
        return cmd

    def submit(self, params: dict) -> Job:
        if not params.get("input") or not os.path.isfile(params["input"]):
            raise ValueError(f"输入文件不存在: {params.get('input')}")
        if not params.get("output"):
            raise ValueError("缺少 output 参数")
        command = self.build_command(params)
        job = Job(uuid.uuid4().hex[:12], params, command)
        with self.lock:
            self.jobs[job.id] = job
        self.queue.put(job)
        return job

    def cancel(self, job_id: str) -> Job:
        job = self.get(job_id)
        if job.status == "queued":
            job.status = "cancelled"
            job.finished_at = time.time()
        elif job.status == "running" and job.process:
            job.status = "cancelled"
            job.process.kill()
        return job

    def get(self, job_id: str) -> Job:
        with self.lock:
            job = self.jobs.get(job_id)
        if not job:
            raise KeyError(job_id)
        return job

    def list_jobs(self):
        with self.lock:
            return list(self.jobs.values())

    def list_models(self):
        aliases = dict(MODEL_ALIASES)
        available = []
        if os.path.isdir(self.models_dir):
            available = sorted(
                d for d in os.listdir(self.models_dir)
                if os.path.isdir(os.path.join(self.models_dir, d))
            )
        return {"aliases": aliases, "models": available}

    def _work_loop(self):
        while True:
            job = self.queue.get()
            if job.status == "cancelled":
                continue
            self._run(job)

    def _run(self, job: Job):
        job.status = "running"
        job.started_at = time.time()
        job.log_tail.append("命令: " + " ".join(job.command))
        try:
            proc = subprocess.Popen(
                job.command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                cwd=ROOT_DIR,
            )
            job.process = proc
            self._read_output(job, proc)
            rc = proc.wait()
        except Exception as e:
            job.status = "failed"
            job.error = str(e)
            job.finished_at = time.time()
            return
        finally:
            job.process = None

        output = job.params["output"]
        if job.status == "cancelled":
            if os.path.isfile(output):
                os.remove(output)  # 清理不完整输出
        elif rc in OK_RETURN_CODES and os.path.isfile(output) and os.path.getsize(output) > 0:
            job.status = "done"
        else:
            job.status = "failed"
            job.error = f"后端返回码 {rc}"
        job.finished_at = time.time()

    def _read_output(self, job: Job, proc):
        """按块读取子进程输出，兼容 \\r 进度刷新，实时解析进度"""
        buf = b""
        fd = proc.stdout.fileno()
        while True:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            buf += chunk
            parts = re.split(rb"[\r\n]+", buf)
            buf = parts.pop()
            for part in parts:
                if not part:
                    continue
                line = part.decode("utf-8", errors="replace")
                job.log_tail.append(line)
                m = TOTAL_RE.search(line)
                if m:
                    job.total_frames = int(m.group(1))
                m = PROGRESS_RE.search(line)
                if m:
                    job.current_frame = int(m.group(1))


class ApiHandler(BaseHTTPRequestHandler):
    manager: JobManager = None  # 由 main() 注入
    server_version = "RVE-API/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length == 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            raise ValueError(f"请求体不是合法 JSON: {e}")

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path in ("", "/health"):
            self._send_json({
                "status": "ok",
                "backend": "ncnn",
                "queued": sum(1 for j in self.manager.list_jobs() if j.status == "queued"),
                "running": sum(1 for j in self.manager.list_jobs() if j.status == "running"),
            })
        elif path == "/models":
            self._send_json(self.manager.list_models())
        elif path == "/jobs":
            self._send_json({"jobs": [j.to_dict() for j in self.manager.list_jobs()]})
        elif path.startswith("/jobs/"):
            try:
                self._send_json(self.manager.get(path[6:]).to_dict(with_log=True))
            except KeyError:
                self._send_json({"error": "任务不存在"}, 404)
        else:
            self._send_json({"error": "未知路径"}, 404)

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/")
        if path != "/jobs":
            self._send_json({"error": "未知路径"}, 404)
            return
        try:
            job = self.manager.submit(self._read_json())
            self._send_json({"job_id": job.id, "status": job.status}, 202)
        except ValueError as e:
            self._send_json({"error": str(e)}, 400)

    def do_DELETE(self):
        path = self.path.split("?")[0].rstrip("/")
        if path.startswith("/jobs/"):
            try:
                job = self.manager.cancel(path[6:])
                self._send_json({"job_id": job.id, "status": job.status})
            except KeyError:
                self._send_json({"error": "任务不存在"}, 404)
        else:
            self._send_json({"error": "未知路径"}, 404)


def main():
    parser = argparse.ArgumentParser(description="RVE 后端 HTTP API 服务 (NCNN)")
    parser.add_argument("--host", default="127.0.0.1", help="监听地址 (默认 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8877, help="监听端口 (默认 8877)")
    parser.add_argument("--models_dir", default=os.path.join(ROOT_DIR, "models"))
    parser.add_argument("--ffmpeg_path", default=os.path.join(ROOT_DIR, "bin", "ffmpeg"))
    args = parser.parse_args()

    ApiHandler.manager = JobManager(args.models_dir, args.ffmpeg_path)
    server = ThreadingHTTPServer((args.host, args.port), ApiHandler)
    print(f"RVE API 服务已启动: http://{args.host}:{args.port}")
    print(f"模型目录: {args.models_dir}")
    print(f"ffmpeg:   {args.ffmpeg_path}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
