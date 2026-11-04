# singboxcore（Go c-shared）

嵌入式 **sing-box v1.12.12** 的 C ABI：`SingletStart` / `SingletStop` / `SingletVersion` …

## 构建

```bash
cd native/singboxcore
export GOPROXY=https://goproxy.cn,direct   # 如需
make          # → build/<arch>/libsingboxcore.dylib
# 默认 TAGS 含 with_clash_api / with_quic / with_wireguard / …
```


## 打进 Flutter `.app`

1. 先 `make` 产出 dylib  
2. Xcode Runner 目标有 **Copy singboxcore dylib** Run Script（`scripts/copy_singboxcore_dylib.sh`），在 embed 阶段把 dylib 拷到  
   `Foo.app/Contents/Frameworks/libsingboxcore.dylib`  
3. Swift `SingBoxCoreLoader` 用 `dlopen` 加载；失败时回退到仓库 `native/singboxcore/build/...`（仅开发）

手动拷贝：

```bash
./scripts/copy_singboxcore_dylib.sh /path/to/Singlet.app
```

## C ABI

见 `include/singboxcore.h`。`SingletStart(config_path, clash_api_base_url)` 会：

1. 读 sing-box JSON  
2. 若缺 `experimental.clash_api`，按 URL 注入 `external_controller`  
3. `box.New` + `Start`

## 已知缺口

- 不负责 TUN 权限 / 系统代理  
- Clash YAML → JSON 在 Dart 侧，且协议映射不完整  
- 未嵌入完整 QUIC/WireGuard 以外的特殊 build tag 裁剪（使用默认 `include` 注册表）
