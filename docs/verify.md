# 验收

## 真实数据复现

首帧、滚动、输入类问题在演示库上好了不算修好：条数、正文长短与图片和真实库差得远。在真实库的只读副本上复现：

```bash
mkdir -p /tmp/cuepad-copy
sqlite3 -readonly "<库目录>/cuepad.db" ".backup /tmp/cuepad-copy/cuepad.db"   # 库目录见 LibraryLocation
mkdir -p /tmp/cuepad-copy/Caches && cp -cR ~/Library/Caches/CuePadAttachments /tmp/cuepad-copy/Caches/   # 要看附件时：本机那份
cp -cR "<库目录>/Attachments" /tmp/cuepad-copy/   # 还没上传的保底
CUEPAD_SHOT_LIBRARY=/tmp/cuepad-copy apple/scripts/xc.sh shot mac …
```

`.backup` 在正式版开着库时也拷得出一致的一份；直接 `cp` 会漏掉 WAL 里没落盘的写入。副本里是用户的私人内容，验完删掉 `/tmp/cuepad-copy`。

## 占前台

占前台会抢用户的键盘、移指针：只在要和交互预算比的数字上用，一次量够、不连跑；新加的要占前台的自动化只经 `DebugForeground`。

## 共用的东西

- 机器上常开着正式版和别的检出的实例：bcu、xctrace 只按 PID 认，按名字或 bundle id 会认到正式版。
- 模拟器槽位全机共用：在里面改过的系统设置（旁白、语言、减少动态效果）验完还原再 `xc.sh stop`，否则下一个任务接着带着。
- 真机日志（`xc.sh diag`）里可能有用户的内容：只在本机读，回给用户与写进报告的只放条数和脱敏后的样子。

## 通知

产物目录里的构建拿不到通知权限（日志 `Failed to find or validate client`）：复制成 `~/Applications/CuePad Notify.app`（别的名字，不覆盖用户装的 `CuePad.app`），改掉 `CFBundleIdentifier` 再 ad-hoc 重签名，用 `open -n -g --env …` 带上 `app_env.py` 的 `isolated_env` 那几个目录启动；验完删掉副本。
