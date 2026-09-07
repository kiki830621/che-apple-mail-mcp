## ADDED Requirements

### Requirement: Composing tools never inject a body via AppleScript

The system SHALL NOT assign an outgoing message's body through the AppleScript `content` property, the `html content` property, or a `content:` entry in `make new outgoing message with properties`. Apple Mail wraps any AppleScript-assigned body in `<blockquote type="cite">` at MIME serialization, which several mail clients render as a quotation of the sender's own text and which the sender cannot observe locally.

Every composing tool SHALL obtain its body exclusively from Mail's own editor — via the `mailto:` hand-off for `compose_email` / `create_draft`, and via the native reply/forward verb plus paste for `reply_email` / `forward_email`.

#### Scenario: No composing path assigns content via AppleScript

- **WHEN** the AppleScript emitted by any composing tool is inspected
- **THEN** it SHALL contain no `set content`, no `set html content`, and no `content:` property in an outgoing-message construction

#### Scenario: A successful compose produces an unwrapped body

- **WHEN** `create_draft` succeeds with `format: "plain"`
- **THEN** the saved draft's source SHALL NOT contain `<blockquote type="cite">` wrapping the supplied body

### Requirement: Ineligible composing calls fail without side effects

When a composing tool cannot use its non-injecting path, it SHALL fail with an error that names the reason and states an actionable alternative, and SHALL NOT create a draft, send mail, or delete an existing draft.

The set of ineligibility reasons SHALL be exactly the following six, and SHALL NOT be extended by analogy:

1. `format` is `markdown` or `html`
2. the subject is empty (the clean path identifies its compose window by title)
3. Accessibility is not granted (GUI keystrokes are unavailable)
4. a supplied `from_address` is not a simple addr-spec
5. an attachment path contains non-ASCII characters
6. a `cc` or `bcc` recipient carries a display name

#### Scenario: Missing Accessibility fails and names the zero-TCC alternative

- **WHEN** `create_draft` is invoked while Accessibility is not granted
- **THEN** the tool SHALL fail naming Accessibility as the reason
- **AND** the error SHALL name `open_mailto` as an alternative that requires no TCC grant, noting that it cannot carry attachments
- **AND** no draft SHALL be created

#### Scenario: Non-ASCII attachment path fails with the manual recipe

- **WHEN** `create_draft` is invoked with an attachment path containing non-ASCII characters
- **THEN** the tool SHALL fail naming the path as the reason
- **AND** the error SHALL direct the caller to create the draft without `attachments` and attach the file manually
- **AND** no draft SHALL be created

#### Scenario: Display-name cc fails rather than degrading silently

- **WHEN** `compose_email` is invoked with `cc: ["王小明 <ming@example.com>"]`
- **THEN** the tool SHALL fail naming display-name cc/bcc as the reason
- **AND** the error SHALL direct the caller to supply a bare address
- **AND** no mail SHALL be sent

### Requirement: Runtime composing failures propagate without falling back

When a composing tool's non-injecting path fails **after** it has begun operating — a GUI keystroke that does not land, a paste that does not take, a send stage that errors — the system SHALL propagate the error to the caller and SHALL NOT retry the operation through any body-assigning path.

Such a failure is distinct from the pre-flight ineligibility contract: it occurs after side effects are possible, so the error message SHALL describe how far the operation progressed and SHALL NOT claim that nothing happened. The existing post-dispatch classification (which distinguishes a failure before dispatch from one after it, so a caller can tell whether retrying risks a duplicate) SHALL continue to govern retry safety.

#### Scenario: A mid-operation GUI failure surfaces rather than falling back

- **WHEN** a composing tool's clean path opens its window and a subsequent GUI step fails
- **THEN** the tool SHALL return an error describing the failure
- **AND** the tool SHALL NOT assign the body through AppleScript as a fallback

#### Scenario: A post-dispatch failure is not presented as a no-op

- **WHEN** a send-stage failure occurs after the message has been dispatched
- **THEN** the error SHALL retain its post-dispatch classification so the caller can tell that retrying risks sending twice
- **AND** the error SHALL NOT state that no mail was sent

## MODIFIED Requirements

### Requirement: Composing tools accept a format parameter

The system SHALL provide four composing MCP tools — `compose_email`, `create_draft`, `reply_email`, and `forward_email` — each accepting an optional `format` parameter whose only permitted value is `"plain"`. When `format` is omitted or null, the system SHALL treat the request as `format: "plain"`.

The system SHALL reject `format: "markdown"` and `format: "html"` with an error that names the removal and directs the caller to `"plain"`. Rich-text bodies are not representable on any non-injecting path, and every injecting path has been removed.

#### Scenario: Format parameter omitted defaults to plain

- **WHEN** a caller invokes `compose_email` with body `"Hi\n\n*Regards*"` and no `format` argument
- **THEN** the body SHALL be delivered verbatim, with `*Regards*` appearing literally

#### Scenario: Markdown is rejected with a named reason

- **WHEN** a caller invokes any composing tool with `format: "markdown"`
- **THEN** the tool SHALL fail with an error naming `markdown` as removed and directing the caller to `"plain"`
- **AND** no draft SHALL be created and no mail SHALL be sent

#### Scenario: HTML is rejected with a named reason

- **WHEN** a caller invokes any composing tool with `format: "html"`
- **THEN** the tool SHALL fail with an error naming `html` as removed and directing the caller to `"plain"`
- **AND** no draft SHALL be created and no mail SHALL be sent

#### Scenario: Invalid format value is rejected

- **WHEN** a caller invokes any composing tool with `format: "rtf"`
- **THEN** the tool SHALL fail with a validation error naming the permitted value

### Requirement: From-scratch composing tools accept cc and bcc recipients

The `compose_email` and `create_draft` MCP tools SHALL each accept optional `cc` and `bcc` parameters, each an array of recipient email-address strings. When provided, the system SHALL set the corresponding Apple Mail `cc recipients` / `bcc recipients` of the outgoing message. The `cc` and `bcc` properties SHALL NOT appear in the `required` array of either tool schema, and omitting them SHALL produce behavior identical to the pre-existing single-recipient (`to`-only) path. Recipient addresses supplied via `cc` / `bcc` SHALL be validated at the boundary identically to `to` recipients.

`cc` and `bcc` addresses SHALL be bare addr-specs. A display-name form (`Name <addr>`) SHALL cause the call to fail per the ineligibility contract, because a `mailto:` URL carries only addr-spec per RFC 6068. `to` recipients SHALL continue to accept display names, which the clean path fills through the GUI.

> `reply_email` instead exposes `cc_additional` (recipients added on top of those derived from `reply_all`) — a reply-context parameter with distinct semantics — and is not covered by this requirement. `forward_email` does not currently accept `cc` / `bcc`.

#### Scenario: create_draft schema advertises cc and bcc

- **WHEN** the `create_draft` tool schema is inspected
- **THEN** it SHALL expose optional `cc` and `bcc` array parameters

#### Scenario: Display-name cc is refused

- **WHEN** `create_draft` is invoked with `cc: ["Name <a@b.co>"]`
- **THEN** the tool SHALL fail per the ineligibility contract and create no draft

### Requirement: Composing tools input schema exposes format parameter

Each composing tool's input schema SHALL expose `format` as an optional string with an enum of exactly `["plain"]`, and SHALL describe it as the only supported body format. The schema SHALL NOT expose `require_wrapper_free`.

#### Scenario: Schema advertises the single permitted format

- **WHEN** any composing tool's schema is inspected
- **THEN** `format` SHALL be present with enum `["plain"]`
- **AND** `require_wrapper_free` SHALL be absent

### Requirement: Plain mode preserves existing behavior

When `format` is `"plain"`, the system SHALL deliver the `body` parameter verbatim: HTML tags SHALL appear literally in the delivered email and no HTML rendering SHALL occur. The body SHALL reach the message through Mail's own editor — the `mailto:` hand-off or the native reply/forward verb plus paste — and SHALL NOT be assigned through the AppleScript `content` property, which is what produces the `<blockquote type="cite">` wrapper.

#### Scenario: Plain body is delivered literally

- **WHEN** a caller invokes `compose_email` with `body: "<b>bold</b>"` and `format: "plain"`
- **THEN** the delivered email SHALL show the characters `<b>bold</b>` literally

#### Scenario: Plain body is not assigned via AppleScript content

- **WHEN** the AppleScript emitted for a plain compose is inspected
- **THEN** it SHALL NOT assign the body through `content` or `html content`

## REMOVED Requirements

### Requirement: Markdown mode honors opt-in URL scheme allowlist via `sanitize_links`

**Reason**: `sanitize_links` governs link rendering during markdown-to-HTML conversion, which only the composing tools' markdown mode performed. With markdown compose removed, the parameter has no behavior to govern on any composing tool. It was never exposed by the export path, which uses a separate renderer.

**Migration**: Callers SHALL remove the `sanitize_links` argument from composing-tool calls. No equivalent is required, because plain bodies are delivered verbatim and perform no link parsing.

### Requirement: Reply and forward wrap original content in HTML blockquote

**Reason**: The requirement is conditioned on `format` being `"markdown"` or `"html"` for `reply_email` / `forward_email`, and both values are removed. Its body-construction steps also assign `html content`, an injection point this change eliminates.

**Migration**: None required. `reply_email` / `forward_email` invoke Mail's native reply/forward verb, and Mail itself produces the quoted original in its usual form. Quoting the original message remains correct behavior; what is removed is this project constructing that quotation via AppleScript assignment.


### Requirement: Markdown mode renders via AttributedString

**Reason**: Markdown rendering assigns HTML to the AppleScript `html content` property, which is one of the injection points Apple Mail wraps in `<blockquote type="cite">`. The wrapper cannot be prevented while any path assigns a body this way, and preventing it completely is the purpose of this change.

**Migration**: Callers SHALL use `format: "plain"`. Markdown rendering remains available for the export path (`batch_export_emails_markdown`); only its use by composing tools is removed. An alternative rich-text compose architecture is tracked separately in #308 / #309.

### Requirement: HTML mode writes body to AppleScript html content

**Reason**: This requirement names the injection directly. Assigning `html content` is what produces the wrapper.

**Migration**: Callers SHALL use `format: "plain"`. There is no HTML compose path; a caller needing HTML delivery SHALL follow #308 / #309.

### Requirement: Markdown rendering has documented Foundation parser limitations

**Reason**: The requirement documents behavior of the markdown compose path, which no longer exists.

**Migration**: None required for composing tools. The equivalent limitations, where they still apply to the export path, are documented by that path's own specification.

### Requirement: Wrapper-free strictness parameter

**Reason**: `require_wrapper_free` existed to let a caller opt out of a silent fallback to the wrapper-producing path. With that path removed there is nothing to opt out of, and retaining a permanently-true flag would imply a control the caller no longer has.

**Migration**: Callers SHALL remove the `require_wrapper_free` argument. Its `true` behavior — fail with a named reason rather than produce a wrapped body — is now unconditional and is specified by "Ineligible composing calls fail without side effects".
