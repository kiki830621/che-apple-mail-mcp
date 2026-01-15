# che-apple-mail-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

**The most comprehensive Apple Mail MCP server** - 42 tools covering nearly all Mail.app scripting capabilities.

[English](README.md) | [繁體中文](README_zh-TW.md)

---

## Why che-apple-mail-mcp?

| Feature | Other MCPs | che-apple-mail-mcp |
|---------|------------|-------------------|
| Total Tools | ~20 | **42** |
| Language | Python | **Swift (Native)** |
| Mailbox Management | Basic | Full CRUD |
| Email Colors | No | 7 flag colors + background |
| VIP Management | No | Yes |
| Rule Management | Partial | Full CRUD |
| Signatures | No | Yes |
| SMTP Servers | No | Yes |
| Email Redirect | No | Yes |
| Raw Headers/Source | No | Yes |

---

## Quick Start

```bash
# Clone and build
git clone https://github.com/kiki830621/che-apple-mail-mcp.git
cd che-apple-mail-mcp
swift build -c release

# Copy to ~/bin and add to Claude Code
# --scope user    : available across all projects (stored in ~/.claude.json)
# --transport stdio: local binary execution via stdin/stdout
# --              : separator between claude options and the command
mkdir -p ~/bin
cp .build/release/CheAppleMailMCP ~/bin/
claude mcp add --scope user --transport stdio che-apple-mail-mcp -- ~/bin/CheAppleMailMCP
```

> **💡 Tip:** Always install the binary to a local directory like `~/bin/`. Avoid placing it in cloud-synced folders (Dropbox, iCloud, OneDrive) as file sync operations can cause MCP connection timeouts.

Then grant Automation permission in **System Settings > Privacy & Security > Automation**.

---

## All 42 Tools

<details>
<summary><b>Accounts (2)</b></summary>

| Tool | Description |
|------|-------------|
| `list_accounts` | List all mail accounts |
| `get_account_info` | Get account details |

</details>

<details>
<summary><b>Mailboxes (4)</b></summary>

| Tool | Description |
|------|-------------|
| `list_mailboxes` | List all mailboxes (folders) |
| `create_mailbox` | Create a new mailbox |
| `delete_mailbox` | Delete a mailbox |
| `get_special_mailboxes` | Get special mailbox names (inbox, drafts, sent, trash, junk, outbox) |

</details>

<details>
<summary><b>Emails (7)</b></summary>

| Tool | Description |
|------|-------------|
| `list_emails` | List emails in a mailbox |
| `get_email` | Get full email content |
| `search_emails` | Search by subject/content |
| `get_unread_count` | Get unread count |
| `get_email_headers` | Get all email headers |
| `get_email_source` | Get raw email source |
| `get_email_metadata` | Get metadata (forwarded, replied, size) |

</details>

<details>
<summary><b>Actions (8)</b></summary>

| Tool | Description |
|------|-------------|
| `mark_read` | Mark as read/unread |
| `flag_email` | Flag/unflag email |
| `set_flag_color` | Set flag color (7 colors) |
| `set_background_color` | Set email background color |
| `mark_as_junk` | Mark as junk/not junk |
| `move_email` | Move to another mailbox |
| `copy_email` | Copy to another mailbox |
| `delete_email` | Delete email (to trash) |

</details>

<details>
<summary><b>Compose (5)</b></summary>

| Tool | Description |
|------|-------------|
| `compose_email` | Send new email |
| `reply_email` | Reply to email |
| `forward_email` | Forward email |
| `redirect_email` | Redirect email (keeps original sender) |
| `open_mailto` | Open mailto URL |

</details>

<details>
<summary><b>Drafts (2)</b></summary>

| Tool | Description |
|------|-------------|
| `list_drafts` | List draft emails |
| `create_draft` | Create a draft |

</details>

<details>
<summary><b>Attachments (2)</b></summary>

| Tool | Description |
|------|-------------|
| `list_attachments` | List email attachments |
| `save_attachment` | Save attachment to disk |

</details>

<details>
<summary><b>VIP (1)</b></summary>

| Tool | Description |
|------|-------------|
| `list_vip_senders` | List VIP senders |

</details>

<details>
<summary><b>Rules (5)</b></summary>

| Tool | Description |
|------|-------------|
| `list_rules` | List mail rules |
| `get_rule_details` | Get rule details |
| `create_rule` | Create a new rule |
| `delete_rule` | Delete a rule |
| `enable_rule` | Enable/disable a rule |

</details>

<details>
<summary><b>Signatures (2)</b></summary>

| Tool | Description |
|------|-------------|
| `list_signatures` | List email signatures |
| `get_signature` | Get signature content |

</details>

<details>
<summary><b>SMTP (1)</b></summary>

| Tool | Description |
|------|-------------|
| `list_smtp_servers` | List SMTP servers |

</details>

<details>
<summary><b>Sync (2)</b></summary>

| Tool | Description |
|------|-------------|
| `check_for_new_mail` | Check for new mail |
| `synchronize_account` | Sync IMAP account |

</details>

<details>
<summary><b>Utilities (4)</b></summary>

| Tool | Description |
|------|-------------|
| `extract_name_from_address` | Extract name from email address |
| `extract_address` | Extract email from full address |
| `get_mail_app_info` | Get Mail.app info |
| `import_mailbox` | Import mailbox from file |

</details>

---

## Installation

### Requirements

- macOS 13.0+
- Xcode Command Line Tools
- Apple Mail with at least one account configured

### Step 1: Build

```bash
git clone https://github.com/kiki830621/che-apple-mail-mcp.git
cd che-apple-mail-mcp
swift build -c release
```

### Step 2: Configure

#### For Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "che-apple-mail-mcp": {
      "command": "/full/path/to/che-apple-mail-mcp/.build/release/CheAppleMailMCP"
    }
  }
}
```

#### For Claude Code (CLI)

```bash
# Copy to ~/bin and register (user scope = available in all projects)
mkdir -p ~/bin
cp .build/release/CheAppleMailMCP ~/bin/
claude mcp add --scope user --transport stdio che-apple-mail-mcp -- ~/bin/CheAppleMailMCP
```

### Step 3: Grant Permissions

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
```

1. Find **CheAppleMailMCP** and enable permission for **Mail.app**
2. If using Claude Code, also add **Terminal** or **iTerm**

### Step 4: Restart Claude

```bash
# For Claude Desktop
osascript -e 'quit app "Claude"' && sleep 2 && open -a "Claude"

# For Claude Code - start a new session
claude
```

---

## Usage Examples

### Natural Language (Claude Desktop)

```
"List all my mail accounts"
"Show unread emails in Gmail inbox"
"Search for emails about 'quarterly report'"
"Send an email to john@example.com about the meeting"
"Flag important emails in red"
"Create a rule to move newsletters to a folder"
```

### Direct Tool Calls (Claude Code)

```
"Use list_accounts to show my accounts"
"Use search_emails to find emails containing 'invoice'"
"Use set_flag_color to mark email ID 12345 as blue"
"Use check_for_new_mail to refresh"
```

---

## Flag & Background Colors

### Flag Colors (`set_flag_color`)

| Index | Color |
|-------|-------|
| 0 | Red |
| 1 | Orange |
| 2 | Yellow |
| 3 | Green |
| 4 | Blue |
| 5 | Purple |
| 6 | Gray |
| -1 | Clear |

### Background Colors (`set_background_color`)

`blue`, `gray`, `green`, `none`, `orange`, `purple`, `red`, `yellow`

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Server disconnected | Rebuild with `swift build -c release` |
| Not allowed to send Apple events | Add permissions in System Settings > Automation |
| Mail.app not responding | Ensure Mail.app is running with configured accounts |
| Commands timing out | Large mailboxes take longer; try specific searches |

---

## Technical Details

- **Framework**: [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) v0.10.0
- **Automation**: AppleScript via `NSAppleScript`
- **Transport**: stdio
- **Platform**: macOS 13.0+ (Ventura and later)

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Author

Created by **Che Cheng** ([@kiki830621](https://github.com/kiki830621))

If you find this useful, please consider giving it a star!
