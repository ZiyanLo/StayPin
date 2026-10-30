# StayPin

A minimal macOS menu-bar utility that keeps a live window view on top and brings the original window forward when you move the pointer into it.

[Download StayPin 2.7](https://github.com/ZiyanLo/StayPin/releases/download/v2.7/StayPin.zip) · [中文说明](#中文说明)

<img src="docs/app-icon.png" width="96" alt="StayPin: a black pin on a white background">

## Use

1. Unzip `StayPin.zip`, move `StayPin.app` to Applications, and open it.
2. In Settings, enable Accessibility (called device control on some macOS versions) and Screen Recording for StayPin.
3. Select a window and click the menu-bar pin, or press **Control + Option + T**.
4. Repeat on the same window to unpin it. Select another window and use the same action to switch the pinned target.
5. Move the pointer into the pinned view to bring the original window forward, then interact normally. This is enabled by default and can be disabled in Settings.

The menu-bar pin is outlined when idle and filled when a window is pinned. **Hold it for about 0.45 seconds or right-click** to open Settings and Quit.

Requires an Apple Silicon Mac. macOS 14 or newer is recommended for full window-frame and shadow support; tested on macOS 27. The distributed build is arm64 and locally signed, without Apple notarization. macOS may ask you to confirm opening it. Updates may require you to enable permissions again.

## How it works and limits

StayPin uses ScreenCaptureKit to display a live view in a floating panel, then hands interaction back to the original window. It does not change the native window level of another app.

- The view can appear above other apps and in other full-screen Spaces.
- **Interacting with it activates the original window and returns to its desktop. It cannot accept background input while you remain in another app’s full-screen Space.**
- If the view appears beneath a stationary pointer, move out and back in to activate it. This prevents focus-switch loops.
- Menus, child windows and protected content may have limitations.
- Screen content stays in local memory. StayPin records no audio, saves no video, and uploads no captured content.

## Build

Install Apple’s Xcode Command Line Tools, then run:

```sh
git clone https://github.com/ZiyanLo/StayPin.git
cd StayPin
./build.sh
open build/StayPin.app
```

The script uses Swift, AppKit, ScreenCaptureKit and the system icon tools. It creates an arm64 app in `build/` and applies a local signature. The bundle identifier remains `local.windowpin.lite` for compatibility with earlier local versions.

## 中文说明

StayPin 是一个极简的 macOS 菜单栏窗口置顶工具：保持整窗实时画面可见，鼠标移入时唤起原窗口进行操作。

- 选中窗口，单击菜单栏图钉或按 **Control + Option + T** 置顶。
- 同一窗口再操作一次取消置顶；选中其他窗口后操作，会切换置顶目标。
- 空心图钉表示未置顶，实心图钉表示已置顶。
- 长按约 0.45 秒或右键打开“设置”和“退出”。
- 默认开启“移入即可操作”，可在设置中关闭。
- 首次使用需开启设备控制（辅助功能）和屏幕录制权限。设置页只显示缺少的授权入口。

实现方式是实时画面加原窗口交接。**在其他应用的全屏空间内操作时，会返回原窗口所在桌面。** 它与应用自身提供的原生置顶不同，不会修改其他应用原窗口的系统层级。

安装包适用于 Apple 芯片 Mac；建议 macOS 14 或更新版本，已在 macOS 27 测试。应用使用本机临时签名，未公证；更新后可能需要重新开启权限。
