# Install Usage Radar

## English Installation Guide

### 1. Download

Open the GitHub Releases page and download:

```text
UsageRadar-1.1-macOS.dmg
```

The app is built as a universal macOS app for both Apple Silicon and Intel Macs.

### 2. Install

1. Open the `.dmg`.
2. Drag **Usage Radar.app** into **Applications**.
3. Launch **Usage Radar** from Applications.
4. If macOS shows a privacy prompt asking to access local app data, click **Allow**. This is required so Usage Radar can read local Codex and Claude usage files.

If macOS blocks the app because it is not notarized, right-click **Usage Radar.app**, choose **Open**, then confirm.

### 3. Check Codex Usage

Codex usually works automatically if you are already logged in locally. Usage Radar reads your existing local Codex login and displays:

```text
5-hour remaining / 7-day remaining
```

### 4. Connect Claude Usage

For the most accurate Claude percentages:

1. Open **Usage Radar**.
2. Click **连接 Claude 账号**.
3. Authorize in the browser.
4. Copy the authorization code shown by Claude.
5. Paste it back into Usage Radar.
6. Click refresh.

After this, Claude 5-hour and 7-day usage will sync from the official authenticated usage endpoint.

### 5. Optional Claude Code Status Line Fallback

If you use Claude Code in terminal sessions, you can also install the fallback status line script:

1. Copy `Scripts/claude-quota-radar-statusline.sh` to:

```text
~/.claude/quota-radar-statusline.sh
```

2. Make it executable:

```bash
chmod +x ~/.claude/quota-radar-statusline.sh
```

3. Add this to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/YOUR_NAME/.claude/quota-radar-statusline.sh",
    "padding": 0,
    "refreshInterval": 30
  }
}
```

This is only a fallback. Connecting Claude directly inside Usage Radar is more stable.

### 6. Use

- The menu bar shows Codex and Claude remaining percentages.
- Open the menu bar item to refresh or show/hide the desktop widget.
- The desktop widget can be covered by normal windows, so it behaves like a lightweight companion panel.

## 中文安装说明

### 1. 下载

在 GitHub Releases 页面下载：

```text
UsageRadar-1.1-macOS.dmg
```

这个版本是 universal macOS 应用，同时支持 Apple Silicon 和 Intel Mac。

### 2. 安装

1. 打开 `.dmg` 文件。
2. 把 **Usage Radar.app** 拖到 **Applications / 应用程序**。
3. 从应用程序里打开 **Usage Radar**。
4. 如果 macOS 弹出“是否允许访问其他 App 的数据”，点 **允许**。这是为了读取本机 Codex / Claude 用量文件。

如果 macOS 提示未公证、无法直接打开，可以右键 **Usage Radar.app**，选择 **打开**，再确认一次。

### 3. 查看 Codex 用量

如果你本机已经登录过 Codex，通常不需要额外设置。Usage Radar 会读取本机 Codex 登录状态并显示：

```text
5 小时剩余 / 7 天剩余
```

### 4. 连接 Claude 用量

想要 Claude 百分比最准确，建议连接 Claude 账号：

1. 打开 **Usage Radar**。
2. 点击 **连接 Claude 账号**。
3. 在浏览器里授权。
4. 复制 Claude 页面显示的授权码。
5. 粘贴回 Usage Radar。
6. 点击刷新。

之后 Claude 的 5 小时和 7 天用量会从官方认证接口同步。

### 5. 可选：Claude Code statusLine 兜底

如果你主要在终端里使用 Claude Code，也可以安装 statusLine 兜底脚本：

1. 复制脚本：

```text
Scripts/claude-quota-radar-statusline.sh
```

到：

```text
~/.claude/quota-radar-statusline.sh
```

2. 添加执行权限：

```bash
chmod +x ~/.claude/quota-radar-statusline.sh
```

3. 在 `~/.claude/settings.json` 加入：

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/YOUR_NAME/.claude/quota-radar-statusline.sh",
    "padding": 0,
    "refreshInterval": 30
  }
}
```

这只是兜底方案。更推荐直接在 Usage Radar 里连接 Claude 账号，稳定性更好。

### 6. 使用

- 菜单栏直接显示 Codex 和 Claude 的剩余百分比。
- 点击菜单栏可以刷新，也可以显示或隐藏桌面小窗。
- 桌面小窗是轻量毛玻璃面板，可以被普通窗口盖住，不会一直挡在最前面。
