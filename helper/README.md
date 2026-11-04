# Privileged Helper（TUN）

macOS TUN 需要 root。个人 MVP 用 **osascript 管理员提权** 安装（不依赖 SMJobBless 签名）。

## 能力（0.3）

- launchd 常驻
- Unix socket：`/var/run/com.singlet.helper.sock`（JSON 行协议）
- `ping` / `status` / `start` / `stop`：以 root `dlopen` 应用内 `libsingboxcore.dylib` 并 `SingletStart` 带 TUN 的配置

## 构建

```bash
./scripts/build_privileged_helper.sh
```

产物打进 `Singlet.app/Contents/Resources/Helper/`（Xcode Run Script）。

## 安装 / 检查

App「设置」一键安装，或：

```bash
launchctl print system/com.singlet.PrivilegedHelper
/Library/PrivilegedHelperTools/com.singlet.PrivilegedHelper --version
ls -l /var/run/com.singlet.helper.sock
cat /tmp/com.singlet.PrivilegedHelper.err.log
```

升级 Helper 后请在设置里 **重新安装**，否则仍是旧二进制（无 socket）。

## 卸载

```bash
sudo launchctl bootout system/com.singlet.PrivilegedHelper
sudo rm -f /Library/LaunchDaemons/com.singlet.PrivilegedHelper.plist
sudo rm -f /Library/PrivilegedHelperTools/com.singlet.PrivilegedHelper
sudo rm -f /var/run/com.singlet.helper.sock
```
