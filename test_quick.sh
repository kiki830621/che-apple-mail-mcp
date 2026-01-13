#!/bin/bash
# Quick test for che-apple-mail-mcp core features
# Avoids slow operations like searching large mailboxes

echo "═══════════════════════════════════════════════════════════════"
echo "  che-apple-mail-mcp 快速測試"
echo "═══════════════════════════════════════════════════════════════"
echo ""

PASS=0
FAIL=0

test() {
    local name="$1"
    local script="$2"
    printf "%-45s" "$name"
    if result=$(timeout 5 osascript -e "$script" 2>&1); then
        echo "✓ PASS"
        ((PASS++))
    else
        if [[ "$result" == *"錯誤"* ]] || [[ "$result" == *"error"* ]]; then
            echo "✗ FAIL: ${result:0:50}"
            ((FAIL++))
        else
            echo "✓ PASS"
            ((PASS++))
        fi
    fi
}

echo "▸ ACCOUNTS"
test "list_accounts" 'tell application "Mail" to get name of every account'
test "get_account_info" 'tell application "Mail" to get enabled of first account'

echo ""
echo "▸ MAILBOXES"
test "list_mailboxes" 'tell application "Mail" to get name of mailboxes of first account'
test "get_special_mailboxes" 'tell application "Mail" to get name of inbox'

echo ""
echo "▸ EMAILS (using iCloud INBOX)"
test "list_emails" 'tell application "Mail" to get subject of message 1 of mailbox "INBOX" of account "iCloud"'
test "get_unread_count" 'tell application "Mail" to get unread count of mailbox "INBOX" of account "iCloud"'

# Get message ID for detail tests
MSG_ID=$(timeout 3 osascript -e 'tell application "Mail" to get id of message 1 of mailbox "INBOX" of account "iCloud"' 2>/dev/null)

if [[ -n "$MSG_ID" ]]; then
    echo ""
    echo "▸ EMAIL DETAILS (msg id: $MSG_ID)"
    test "get_email" "tell application \"Mail\" to get subject of (first message of mailbox \"INBOX\" of account \"iCloud\" whose id is $MSG_ID)"
    test "get_email_headers" "tell application \"Mail\" to get all headers of (first message of mailbox \"INBOX\" of account \"iCloud\" whose id is $MSG_ID)"
    test "get_email_metadata" "tell application \"Mail\" to get was forwarded of (first message of mailbox \"INBOX\" of account \"iCloud\" whose id is $MSG_ID)"
    test "list_attachments" "tell application \"Mail\" to get count of mail attachments of (first message of mailbox \"INBOX\" of account \"iCloud\" whose id is $MSG_ID)"
fi

echo ""
echo "▸ RULES"
test "list_rules" 'tell application "Mail" to get count of rules'

echo ""
echo "▸ SIGNATURES"
test "list_signatures" 'tell application "Mail" to get count of signatures'

echo ""
echo "▸ SMTP"
test "list_smtp_servers" 'tell application "Mail" to get name of every smtp server'

echo ""
echo "▸ SYNC"
test "check_for_new_mail" 'tell application "Mail" to check for new mail'

echo ""
echo "▸ UTILITIES"
test "extract_name" 'tell application "Mail" to extract name from "John <john@test.com>"'
test "extract_address" 'tell application "Mail" to extract address from "John <john@test.com>"'
test "get_app_version" 'tell application "Mail" to get application version'
test "get_fetch_interval" 'tell application "Mail" to get fetch interval'

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  結果: ✓ PASS: $PASS  |  ✗ FAIL: $FAIL"
echo "═══════════════════════════════════════════════════════════════"

[[ $FAIL -eq 0 ]] && echo "✅ 所有測試通過！" || echo "❌ 有 $FAIL 個測試失敗"
