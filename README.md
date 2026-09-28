# WXKeyboardToolbarPlus

iOS 越狱 tweak，针对**微信输入法**键盘扩展。
Theos + Logos，RootHide / Dopamine rootless 通用。

## 它做了什么

- Hook 键盘顶部工具栏 `WXKeyboardToolbarView`
- **不重写按钮**：原 `layoutSubviews` 跑完后，把所有原生按钮搬到新建的 `UIScrollView`，**保留 frame、target、action**，图标和点击链零修改
- 工具栏容器替换为可横向滚动的 `UIScrollView`，**移除 7 按钮硬编码上限**
- PreferenceLoader 设置面板，按钮级显隐控制

## 目录结构

```
WXKeyboardToolbarPlus/
├── Makefile
├── control
├── filter.plist
├── Tweak.xm
└── layout/
    └── Library/
        └── PreferenceLoader/
            └── Preferences/
                └── WXKeyboardToolbarPlus.plist
```

## 构建

参考 `theos-cloud-build` skill，云端 Actions 编译：

```bash
git init && git add . && git commit -m "init"
# push 到你的私有仓库，然后在 GitHub Actions 跑 Theos 云端构建
```

或者用本机的 theos（需要 macOS / 模拟 rootless 的 macOS runner）：

```bash
make package FINALPACKAGE=1
```

产物：

- `packages/com.gusing.wxkbtoolbarplus_0.1.0_iphoneos-arm64e.deb` → 14PM / RootHide
- 8P（arm64 纯架构）需要把 `ARCHS=arm64` 单独再编一次：`make ARCHS=arm64 package`

## 安装

```bash
dpkg -i com.gusing.wxkbtoolbarplus_0.1.0_iphoneos-arm64e.deb
killall -9 WeType 2>/dev/null
# 调出微信键盘一次，让 NSUserDefaults 写入
```

设置面板在系统 **设置 → 微信键盘工具栏增强**。

## 类名核对（如果 WXKeyboardToolbarView 不存在）

> `objc_getClass("WXKeyboardToolbarView")` 返回 NULL 时，`%ctor` 会打印 `FATAL` 日志。
> 此时需要 class-dump 键盘扩展的真实二进制。

### 在 Windows 上做 class-dump（不需要 Mac）

1. 把微信输入法键盘扩展的 binary 拉下来：
   ```
   scp root@iPhone:/var/containers/Bundle/Application/*/WeType.app/PlugIns/*.appex/WeTypeKeyboard .
   ```
2. 使用 `macho-objc-dump` skill 解析（纯 Python，可在 Windows 跑）：
   ```
   skill: macho-objc-dump
   ```
   让它扫描 `__DATA, __objc_classname`，列出所有 ObjC 类名。
3. 找含 `Toolbar` 的类（一般在 `WeTypeKeyboard` / `KeyboardExtension` 命名空间下）。
4. 把真实类名替换 `Tweak.xm` 里的 `WXKeyboardToolbarView`。

### 在 macOS 上做（如果有 Mac）

```bash
class-dump --arch arm64 WeTypeKeyboard | grep -i toolbar
```

## 与液态玻璃键盘美化共存

- tweak **只改 `WXKeyboardToolbarView` 这一个具体类**
- 不 swizzle 全局方法（`UIView +load` / `+initialize` / 通用 `layoutSubviews`）
- 不动 `backgroundColor` / `tintColor`
- 按钮搬运保留原 frame，液态玻璃插件对按钮本身的 effect（模糊 / 玻璃材质）继续生效
- 如果对方也 hook 了同一个类，按 Sileo/Zebra 的加载顺序，后加载的会先跑（chain order），建议把 WXKeyboardToolbarPlus 排在它之后

## 调整过滤的 bundle id

默认覆盖微信输入法常见的几个 bundle id。如果你的设备上不是这些：

1. 编辑 `filter.plist` 里的 `Bundles` 数组
2. 或者从设备上找：
   ```
   ssh root@iPhone
   find /var/containers/Bundle/Application -name "WeType*.appex" -prune -print
   defaults read /var/mobile/Containers/Shared/AppGroup/*/.com.apple.mobile_container_manager.metadata.plist MCMMetadataIdentifier
   ```

## 隐藏规则细化

`tweak.xm` 里的 `keywordMap` 是默认关键字集，按类名前缀 / `accessibilityIdentifier` 模糊匹配。
如果你 class-dump 后发现某个按钮的实际类名是 `WetypeChatPanelExpandButton`，把对应关键字加进字典即可，例如：

```objc
kPrefHidePanel: @[@"panel", @"chevron", @"arrow", @"expand", @"close", @"wetypechatpanel"],
```

修改后重新编译即可，**不需要重启 SpringBoard**。