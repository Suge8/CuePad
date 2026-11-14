"""perf.py 与 perf_interact.py 共用：起 Mac 实例、种子库、trace、结果行（用法与口径见 perf.py 头注释）。"""
import json
import os
import shutil
import signal
import statistics as st
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
from app_env import APPLE  # noqa: E402
from app_proc import wait_ready  # noqa: E402

SEED = os.environ.get("CUEPAD_PERF_SEED")
TRACE = os.environ.get("CUEPAD_TRACE")
TRACE_WARMUP = 1  # xctrace 报 Starting recording 后采样还要一会儿才真的开始（实测头 0.47 秒没有样本），没有别的信号可等


def fail(message, code=1):
    print(message, file=sys.stderr, flush=True)
    sys.exit(code)


def fresh(library, source=None):
    shutil.rmtree(library, ignore_errors=True)
    if source:
        subprocess.run(["cp", "-cR", source, library], check=True)  # APFS 克隆，不占时间也不占空间
    else:
        os.makedirs(library)


def mac(app, library, args, ready=None, stdout=subprocess.DEVNULL):
    """经 app.py exec 起 Mac 实例（隔离、占住本检出那一份后 exec 成 CuePad）：返回的进程就是 CuePad。"""
    env = dict(os.environ, CUEPAD_SHOT_READY=ready) if ready else None
    return subprocess.Popen([sys.executable, f"{APPLE}/scripts/app.py", "exec", app, library, "--", *args],
                            env=env, stdout=stdout, stderr=subprocess.DEVNULL, text=True)


def stop(proc):
    proc.terminate()
    proc.wait()


def seeded(library, app, args, timeout, what):
    """写一份种子库（就绪后结束），之后的运行才是冷启动。等就绪文件而不是数某张表：就绪在种子整个写完之后（DebugScene.signalReady）。没写完的不留。"""
    if os.path.exists(f"{library}/cuepad.db"):
        return library
    fresh(library)
    ready = f"{library}.ready"
    if os.path.exists(ready):
        os.remove(ready)
    proc = mac(app, library, args, ready)
    try:
        wait_ready(ready, proc.pid, timeout=timeout)
    except SystemExit:
        stop(proc)
        shutil.rmtree(library)
        fail(f"{what}没写完")
    stop(proc)
    return library


def trace_path(derived, name):
    os.makedirs(f"{derived}/traces", exist_ok=True)
    trace = f"{derived}/traces/{name}.trace"
    shutil.rmtree(trace, ignore_errors=True)
    print(f"trace：{trace}", file=sys.stderr, flush=True)
    return trace


def trace_attach(pid, trace):
    """按 PID 录到那个进程退出（xctrace 的输出在同名 .log）；开录了才放 App 往下走，没开录成就结束它，这一次算没量完。"""
    with open(f"{trace}.log", "w") as log:
        xctrace = subprocess.Popen(["xcrun", "xctrace", "record", "--template", TRACE, "--attach", str(pid), "--output", trace],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        started = False
        for line in xctrace.stdout:
            log.write(line)
            if not started and "Starting recording" in line:
                started = True
                time.sleep(TRACE_WARMUP)
                os.kill(pid, signal.SIGUSR1)
        xctrace.wait()
    if not started:
        print(f"xctrace 没开录，见 {trace}.log", file=sys.stderr)
        os.kill(pid, signal.SIGTERM)


def relay(proc, trace, click=None):
    """读 Mac 实例的标准输出：AWAIT trace <PID> 按 PID 开录，AWAIT click x y 真实地点一下，其余行收下。"""
    lines, tracers = [], []
    for line in proc.stdout:
        kind, what, *rest = line.split() + ["", ""]
        if kind == "AWAIT" and what == "trace":
            tracers.append(threading.Thread(target=trace_attach, args=(int(rest[0]), trace)))
            tracers[-1].start()
        elif kind == "AWAIT" and click:
            subprocess.run([click, "click", rest[0], rest[1]], check=True)
        else:
            lines.append(line)
    status = proc.wait()
    for t in tracers:
        t.join()
    return status, lines


def rows_file(derived, name, rows):
    with open(f"{derived}/{name}.jsonl", "w") as f:
        f.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)


def medians(rows, keys):
    for k in keys:
        print(f"{k:26}{st.median(r[k] for r in rows):>10}   各次 {[r[k] for r in rows]}")
