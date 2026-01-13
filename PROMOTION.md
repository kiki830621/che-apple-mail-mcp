# che-apple-mail-mcp Promotion Guide

## 1. MCP Official Servers List PR

### How to Submit

1. Fork https://github.com/modelcontextprotocol/servers
2. Edit README.md in the "Community Servers" section
3. Add this entry (in alphabetical order):

```markdown
- **[che-apple-mail-mcp](https://github.com/kiki830621/che-apple-mail-mcp)** (by Che Cheng) - The most comprehensive Apple Mail MCP with 42 tools covering accounts, mailboxes, emails, rules, signatures, VIP management and more. Built with Swift.
```

4. Create PR with title: `Add che-apple-mail-mcp - Comprehensive Apple Mail MCP`

### PR Description Template

```markdown
## New Community Server: che-apple-mail-mcp

**Repository**: https://github.com/kiki830621/che-apple-mail-mcp

### Description
The most comprehensive Apple Mail MCP server with 42 tools - more than double the tools of existing alternatives. Built natively in Swift using AppleScript for Mail.app automation.

### Features
- 42 tools covering nearly all Mail.app scripting capabilities
- Full mailbox management (CRUD)
- 7 flag colors + background colors
- VIP sender management
- Complete rule management (CRUD)
- Email signatures
- SMTP server info
- Email redirect (preserves original sender)
- Raw headers and source access

### Technical Details
- Language: Swift
- Framework: MCP Swift SDK v0.10.0
- Platform: macOS 13.0+
- Transport: stdio

### Comparison
| Feature | Other MCPs | che-apple-mail-mcp |
|---------|------------|-------------------|
| Tools | ~20 | 42 |
| Language | Python | Swift (native) |
| VIP/Rules/Signatures | Partial/No | Full support |
```

---

## 2. Social Media Posts

### Twitter/X Post

```
Introducing che-apple-mail-mcp - the most comprehensive Apple Mail MCP server

42 tools for complete Mail.app automation:
- Full mailbox & rule management
- 7 flag colors + backgrounds
- VIP, signatures, SMTP
- Email redirect, raw headers

Built natively in Swift

https://github.com/kiki830621/che-apple-mail-mcp

#Claude #MCP #AppleMail #macOS #Swift
```

### Twitter/X Thread Version

```
1/5 Introducing che-apple-mail-mcp - the most comprehensive Apple Mail MCP server with 42 tools

Built natively in Swift, it covers nearly ALL Mail.app scripting capabilities

https://github.com/kiki830621/che-apple-mail-mcp

2/5 What makes it different?

Compared to other Apple Mail MCPs:
- 42 tools vs ~20
- Swift (native) vs Python
- Full CRUD for mailboxes & rules
- 7 flag colors + background colors
- VIP management, signatures, SMTP

3/5 Key Features:
- List/create/delete mailboxes
- Search emails, get headers/source
- Reply, forward, redirect (keeps original sender)
- Manage mail rules programmatically
- Extract names/addresses from email strings

4/5 Installation is simple:

git clone + swift build -c release
Then add to Claude Desktop or Claude Code

Works with macOS 13.0+ (Ventura and later)

5/5 If you use Claude with Apple Mail, give it a try!

Contributions welcome. Star if you find it useful!

#Claude #MCP #AppleMail #macOS #Swift #Automation @AnthropicAI
```

### Reddit Post (r/ClaudeAI)

**Title**: I built the most comprehensive Apple Mail MCP - 42 tools for complete Mail.app automation

**Body**:
```
Hey everyone!

I've been working on an MCP server for Apple Mail and wanted to share it with the community.

**che-apple-mail-mcp** provides 42 tools for Mail.app automation - more than double what other Apple Mail MCPs offer.

### Why I built this

Existing Apple Mail MCPs only cover ~20 basic operations. I wanted complete control over Mail.app through Claude, including:
- Mailbox management (create/delete folders)
- Mail rules (full CRUD)
- VIP senders
- Email signatures
- Flag colors (7 colors!) and background colors
- Email redirect (keeps original sender)
- Raw email headers and source

### Technical details

- Built natively in Swift (not Python)
- Uses AppleScript via NSAppleScript
- Works with Claude Desktop and Claude Code
- macOS 13.0+ required

### Links

- GitHub: https://github.com/kiki830621/che-apple-mail-mcp
- Chinese README available: README_zh-TW.md

Would love any feedback or feature requests!
```

### Reddit Post (r/MacOS)

**Title**: Open source: Complete Apple Mail automation through MCP (Model Context Protocol) - 42 AppleScript tools

**Body**:
```
For anyone using Claude AI with macOS, I built an MCP server that exposes nearly all of Apple Mail's AppleScript capabilities.

**che-apple-mail-mcp** includes 42 tools:

- Account & mailbox management
- Email operations (read, search, move, copy, delete)
- Compose, reply, forward, redirect
- Flag colors (7 colors) and background colors
- Mail rules (list, create, delete, enable/disable)
- Signatures and VIP senders
- SMTP server info
- Raw email headers and source

Built with Swift and the MCP Swift SDK.

GitHub: https://github.com/kiki830621/che-apple-mail-mcp

Happy to answer any questions about the implementation!
```

### Hacker News (Show HN)

**Title**: Show HN: che-apple-mail-mcp – 42-tool Apple Mail MCP server in Swift

**Body**:
```
I built an MCP (Model Context Protocol) server for Apple Mail with 42 tools - covering nearly all Mail.app AppleScript capabilities.

GitHub: https://github.com/kiki830621/che-apple-mail-mcp

Key features:
- Complete mailbox management (CRUD)
- Mail rules management (CRUD)
- 7 flag colors + background colors
- VIP senders, signatures, SMTP info
- Email redirect (preserves original sender)
- Raw headers and source access

Technical stack:
- Swift with MCP Swift SDK v0.10.0
- AppleScript via NSAppleScript
- stdio transport
- macOS 13.0+

Compared to existing Apple Mail MCPs (which offer ~20 tools in Python), this provides more than double the functionality with native Swift performance.

Works with both Claude Desktop and Claude Code CLI.

Feedback welcome!
```

---

## 3. GitHub Repository Settings

### Description (已設定)
```
The most comprehensive Apple Mail MCP server with 42 tools - Swift native, full Mail.app automation for Claude AI
```

### Topics (已設定)
```
mcp, apple-mail, swift, macos, claude, automation, applescript, email, mail-app, model-context-protocol
```

### Social Preview Image (建議)
Consider creating a social preview image (1280x640px) showing:
- Project name
- "42 Tools"
- Apple Mail + Claude logos
- Key feature highlights

---

## 4. Other Promotion Channels

### Awesome MCP Lists
Search for "awesome-mcp" repositories and submit your project.

### Dev.to / Medium Article
Consider writing a technical article about:
- How to build an MCP server in Swift
- Apple Mail AppleScript deep dive
- Automating email workflows with Claude

### YouTube
A demo video showing the MCP in action could be very effective.
