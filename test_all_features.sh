#!/bin/bash
# Test script for che-apple-mail-mcp
# Tests all 42 AppleScript features

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "  che-apple-mail-mcp 功能測試腳本"
echo "  測試所有 42 個 Apple Mail AppleScript 功能"
echo "═══════════════════════════════════════════════════════════════"
echo ""

PASS=0
FAIL=0
SKIP=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

test_feature() {
    local name="$1"
    local script="$2"
    local expected_type="$3"  # "string", "list", "number", "any"

    printf "%-40s" "Testing: $name"

    result=$(osascript -e "$script" 2>&1) || true

    if [[ "$result" == *"error"* ]] || [[ "$result" == *"Error"* ]] || [[ "$result" == *"錯誤"* ]]; then
        echo -e "${RED}✗ FAIL${NC}"
        echo "  Error: $result"
        ((FAIL++))
        return 1
    else
        echo -e "${GREEN}✓ PASS${NC}"
        if [[ -n "$result" ]]; then
            # Truncate long output
            if [[ ${#result} -gt 80 ]]; then
                echo "  Result: ${result:0:80}..."
            else
                echo "  Result: $result"
            fi
        fi
        ((PASS++))
        return 0
    fi
}

skip_feature() {
    local name="$1"
    local reason="$2"
    printf "%-40s" "Testing: $name"
    echo -e "${YELLOW}○ SKIP${NC} ($reason)"
    ((SKIP++))
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. ACCOUNTS (帳戶)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

test_feature "list_accounts" \
    'tell application "Mail" to get name of every account'

# Get first account for subsequent tests
FIRST_ACCOUNT=$(osascript -e 'tell application "Mail" to get name of first account' 2>/dev/null) || FIRST_ACCOUNT=""

if [[ -n "$FIRST_ACCOUNT" ]]; then
    test_feature "get_account_info" \
        "tell application \"Mail\" to get enabled of account \"$FIRST_ACCOUNT\""
else
    skip_feature "get_account_info" "No accounts found"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. MAILBOXES (信箱)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ -n "$FIRST_ACCOUNT" ]]; then
    test_feature "list_mailboxes" \
        "tell application \"Mail\" to get name of every mailbox of account \"$FIRST_ACCOUNT\""
else
    skip_feature "list_mailboxes" "No accounts found"
fi

test_feature "get_special_mailboxes (inbox)" \
    'tell application "Mail" to get name of inbox'

test_feature "get_special_mailboxes (drafts)" \
    'tell application "Mail" to get name of drafts mailbox'

test_feature "get_special_mailboxes (sent)" \
    'tell application "Mail" to get name of sent mailbox'

test_feature "get_special_mailboxes (trash)" \
    'tell application "Mail" to get name of trash mailbox'

test_feature "get_special_mailboxes (junk)" \
    'tell application "Mail" to get name of junk mailbox'

skip_feature "create_mailbox" "會修改資料"
skip_feature "delete_mailbox" "會修改資料"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. EMAILS - READ (郵件讀取)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Find an account with INBOX
INBOX_ACCOUNT=""
for acc in $(osascript -e 'tell application "Mail" to get name of every account' 2>/dev/null | tr ',' '\n'); do
    acc=$(echo "$acc" | xargs)  # trim whitespace
    has_inbox=$(osascript -e "tell application \"Mail\" to get name of mailbox \"INBOX\" of account \"$acc\"" 2>/dev/null) || true
    if [[ "$has_inbox" == "INBOX" ]]; then
        INBOX_ACCOUNT="$acc"
        break
    fi
done

if [[ -n "$INBOX_ACCOUNT" ]]; then
    echo "  Using account: $INBOX_ACCOUNT"

    test_feature "list_emails" \
        "tell application \"Mail\" to get subject of messages 1 thru 3 of mailbox \"INBOX\" of account \"$INBOX_ACCOUNT\""

    test_feature "get_unread_count" \
        "tell application \"Mail\" to get unread count of mailbox \"INBOX\" of account \"$INBOX_ACCOUNT\""

    # Get first message ID for detailed tests
    FIRST_MSG_ID=$(osascript -e "tell application \"Mail\" to get id of message 1 of mailbox \"INBOX\" of account \"$INBOX_ACCOUNT\"" 2>/dev/null) || FIRST_MSG_ID=""

    if [[ -n "$FIRST_MSG_ID" ]]; then
        test_feature "get_email (subject)" \
            "tell application \"Mail\" to get subject of message id $FIRST_MSG_ID of mailbox \"INBOX\" of account \"$INBOX_ACCOUNT\""

        test_feature "get_email (sender)" \
            "tell application \"Mail\" to get sender of message id $FIRST_MSG_ID of mailbox \"INBOX\" of account \"$INBOX_ACCOUNT\""

        test_feature "get_email_headers" \
            "tell application \"Mail\" to get all headers of message id $FIRST_MSG_ID of mailbox \"INBOX\" of account \"$INBOX_ACCOUNT\""

        test_feature "get_email_metadata (was_forwarded)" \
            "tell application \"Mail\" to get was forwarded of message id $FIRST_MSG_ID of mailbox \"INBOX\" of account \"$INBOX_ACCOUNT\""

        test_feature "get_email_metadata (was_replied)" \
            "tell application \"Mail\" to get was replied to of message id $FIRST_MSG_ID of mailbox \"INBOX\" of account \"$INBOX_ACCOUNT\""

        test_feature "get_email_metadata (message_size)" \
            "tell application \"Mail\" to get message size of message id $FIRST_MSG_ID of mailbox \"INBOX\" of account \"$INBOX_ACCOUNT\""

        test_feature "list_attachments" \
            "tell application \"Mail\" to get count of mail attachments of message id $FIRST_MSG_ID of mailbox \"INBOX\" of account \"$INBOX_ACCOUNT\""

        # Skip source as it can be very large
        skip_feature "get_email_source" "輸出太大"
    else
        skip_feature "get_email" "No messages found"
        skip_feature "get_email_headers" "No messages found"
        skip_feature "get_email_metadata" "No messages found"
        skip_feature "list_attachments" "No messages found"
    fi

    test_feature "search_emails" \
        "tell application \"Mail\"
            set foundMsgs to (messages of mailbox \"INBOX\" of account \"$INBOX_ACCOUNT\" whose subject contains \"a\")
            get count of foundMsgs
        end tell"
else
    skip_feature "list_emails" "No INBOX found"
    skip_feature "get_email" "No INBOX found"
    skip_feature "search_emails" "No INBOX found"
    skip_feature "get_unread_count" "No INBOX found"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4. EMAILS - ACTIONS (郵件操作) - SKIPPED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

skip_feature "mark_read" "會修改資料"
skip_feature "flag_email" "會修改資料"
skip_feature "set_flag_color" "會修改資料"
skip_feature "set_background_color" "會修改資料"
skip_feature "mark_as_junk" "會修改資料"
skip_feature "move_email" "會修改資料"
skip_feature "copy_email" "會修改資料"
skip_feature "delete_email" "會修改資料"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5. COMPOSE (撰寫) - SKIPPED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

skip_feature "compose_email" "會發送郵件"
skip_feature "reply_email" "會發送郵件"
skip_feature "forward_email" "會發送郵件"
skip_feature "redirect_email" "會發送郵件"
skip_feature "open_mailto" "會開啟視窗"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "6. DRAFTS (草稿)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ -n "$FIRST_ACCOUNT" ]]; then
    # Check if Drafts mailbox exists
    has_drafts=$(osascript -e "tell application \"Mail\" to get name of mailbox \"Drafts\" of account \"$FIRST_ACCOUNT\"" 2>/dev/null) || has_drafts=""
    if [[ -n "$has_drafts" ]]; then
        test_feature "list_drafts" \
            "tell application \"Mail\" to get count of messages of mailbox \"Drafts\" of account \"$FIRST_ACCOUNT\""
    else
        skip_feature "list_drafts" "No Drafts mailbox"
    fi
else
    skip_feature "list_drafts" "No accounts found"
fi

skip_feature "create_draft" "會建立草稿"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "7. ATTACHMENTS (附件)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

skip_feature "save_attachment" "會寫入檔案"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "8. VIP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# VIP is a smart mailbox, check if it exists
test_feature "list_vip_senders" \
    'tell application "Mail"
        try
            get count of messages of mailbox "VIP"
        on error
            return 0
        end try
    end tell'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "9. RULES (規則)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

test_feature "list_rules" \
    'tell application "Mail" to get name of every rule'

RULE_COUNT=$(osascript -e 'tell application "Mail" to get count of rules' 2>/dev/null) || RULE_COUNT=0

if [[ "$RULE_COUNT" -gt 0 ]]; then
    FIRST_RULE=$(osascript -e 'tell application "Mail" to get name of first rule' 2>/dev/null) || FIRST_RULE=""
    if [[ -n "$FIRST_RULE" ]]; then
        test_feature "get_rule_details (enabled)" \
            "tell application \"Mail\" to get enabled of rule \"$FIRST_RULE\""

        test_feature "get_rule_details (all_conditions)" \
            "tell application \"Mail\" to get all conditions must be met of rule \"$FIRST_RULE\""
    fi
else
    skip_feature "get_rule_details" "No rules found"
fi

skip_feature "create_rule" "會建立規則"
skip_feature "delete_rule" "會刪除規則"
skip_feature "enable_rule" "會修改規則"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "10. SIGNATURES (簽名檔)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

test_feature "list_signatures (count)" \
    'tell application "Mail" to get count of signatures'

SIG_COUNT=$(osascript -e 'tell application "Mail" to get count of signatures' 2>/dev/null) || SIG_COUNT=0

if [[ "$SIG_COUNT" -gt 0 ]]; then
    test_feature "list_signatures (names)" \
        'tell application "Mail" to get name of every signature'

    FIRST_SIG=$(osascript -e 'tell application "Mail" to get name of first signature' 2>/dev/null) || FIRST_SIG=""
    if [[ -n "$FIRST_SIG" ]]; then
        test_feature "get_signature" \
            "tell application \"Mail\" to get content of signature \"$FIRST_SIG\""
    fi
else
    echo "  (No signatures configured)"
    skip_feature "get_signature" "No signatures found"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "11. SMTP SERVERS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

test_feature "list_smtp_servers" \
    'tell application "Mail" to get name of every smtp server'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "12. SYNC (同步)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

test_feature "check_for_new_mail" \
    'tell application "Mail" to check for new mail'

if [[ -n "$FIRST_ACCOUNT" ]]; then
    test_feature "synchronize_account" \
        "tell application \"Mail\" to synchronize account \"$FIRST_ACCOUNT\""
else
    skip_feature "synchronize_account" "No accounts found"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "13. UTILITIES (工具)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

test_feature "extract_name_from_address" \
    'tell application "Mail" to extract name from "John Doe <john@example.com>"'

test_feature "extract_address" \
    'tell application "Mail" to extract address from "John Doe <john@example.com>"'

test_feature "get_mail_app_info (version)" \
    'tell application "Mail" to get application version'

test_feature "get_mail_app_info (fetch_interval)" \
    'tell application "Mail" to get fetch interval'

test_feature "get_mail_app_info (bg_count)" \
    'tell application "Mail" to get background activity count'

skip_feature "import_mailbox" "需要檔案路徑"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  測試結果總結"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo -e "  ${GREEN}✓ PASS: $PASS${NC}"
echo -e "  ${RED}✗ FAIL: $FAIL${NC}"
echo -e "  ${YELLOW}○ SKIP: $SKIP${NC} (會修改資料或需要特定條件)"
echo ""
TOTAL=$((PASS + FAIL + SKIP))
echo "  Total: $TOTAL features"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}✅ 所有可測試的功能都通過了！${NC}"
    exit 0
else
    echo -e "${RED}❌ 有 $FAIL 個功能測試失敗${NC}"
    exit 1
fi
