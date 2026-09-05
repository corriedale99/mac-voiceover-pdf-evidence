#!/bin/zsh

#
# run_voiceover_evidence.sh
#
# Macのプレビュー.appとVoiceOverを使ってPDFを確認し、
# VoiceOverが取得した文字列をevidence.txtへ保存するツールです。
#
# 基本的な使い方:
# ./run_voiceover_evidence.sh "確認するPDF.pdf"
#
# 詳しい準備と操作方法は、同梱のHTMLマニュアルを参照してください。
#
# バージョン: 1.0.0
# 更新日: 2026-09-05
#
set -u
zmodload zsh/datetime

TOOL_VERSION="1.0.0"
SCRIPT_PATH="${0:A}"
TOOL_DIR="${SCRIPT_PATH:h}"
TOOL_NAME="${SCRIPT_PATH:t}"
OUTPUT_ROOT="$TOOL_DIR/output"
PREVIEW_APP="/System/Applications/Preview.app"
VOICEOVER_UTILITY="/System/Applications/Utilities/VoiceOver Utility.app"
GROUPING_REQUIRED="グループを無視"

DEFAULT_MAX_MOVES=200
DEFAULT_MOVE_WAIT=0.3
MIN_MAX_MOVES=1
MAX_MAX_MOVES=1000
MIN_MOVE_WAIT=0.1
MAX_MOVE_WAIT=5.0

TARGET_PDF_INPUT=""
TARGET_PDF=""
TARGET_PDF_NAME=""
TARGET_PDF_INPUT_SAFE=""
MAX_MOVES=$DEFAULT_MAX_MOVES
typeset -F 6 MOVE_WAIT=$DEFAULT_MOVE_WAIT

RUN_DIR=""
RUN_OUTPUT_RELATIVE=""
RAW_LOG=""
EVIDENCE_LOG=""
GROUPING_ERR=""
PREVIEW_ERR=""
VOICEOVER_ERR=""
FRONTMOST_OUT=""
PAGE_OUT=""
CURSOR_TEXT_BEFORE=""
CURSOR_TEXT_AFTER=""
CURSOR_BOUNDS_BEFORE=""
CURSOR_BOUNDS_AFTER=""
PHRASE_BEFORE=""
PHRASE_AFTER=""

RUN_MODE="NORMAL_RUN"
OUTPUT_COLLISION_CANDIDATE=""
grouping_before=""
grouping_after=""
grouping_read=0
total_moves=0
evidence_items_count=0
eof_detected="NO"
eof_reason="NOT_REACHED"
eof_same_streak=0
stop_reason="not_started"
preview_start_page="NOT_READ"
preview_total_pages="NOT_READ"
document_group_bounds="NOT_READ"
run_started_epoch=0

usage() {
    /bin/cat <<EOF
Usage:
  $TOOL_NAME <PDF> [--max-moves <整数>] [--move-wait <秒>]

Examples:
  $TOOL_NAME "Pages-Fixサンプル/コーヒーノキ-iPDF-Pages-Fixサンプル.pdf"
  $TOOL_NAME "/path/to/book.pdf"

Defaults and limits:
  --max-moves  default: $DEFAULT_MAX_MOVES (range: ${MIN_MAX_MOVES}..${MAX_MAX_MOVES})
  --move-wait  default: $DEFAULT_MOVE_WAIT (range: ${MIN_MOVE_WAIT}..${MAX_MOVE_WAIT} seconds)

Platform requirements:
  macOS日本語UIのプレビュー.appとVoiceOverを対象とします。
  VoiceOver Utilityで「AppleScriptによるVoiceOver制御を許可」を有効にし、
  「ナビゲーション → グループ化の動作 → グループを無視」に設定してください。
  本ツールはVoiceOver設定、プレビュー.appの設定、権限ダイアログを変更・操作しません。
EOF
}

die_cli() {
    /usr/bin/printf '%s\n' "エラー: $1" >&2
    usage >&2
    exit 2
}

if (( $# == 0 )); then
    die_cli "PDFが指定されていません"
fi
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    (( $# == 1 )) || die_cli "--helpと他の引数は併用できません"
    usage
    exit 0
fi

TARGET_PDF_INPUT="$1"
shift

while (( $# > 0 )); do
    case "$1" in
        --max-moves)
            (( $# >= 2 )) || die_cli "--max-movesには値が必要です"
            [[ "$2" =~ '^[1-9][0-9]*$' ]] || die_cli "--max-movesは1以上の整数で指定してください"
            (( $2 >= MIN_MAX_MOVES && $2 <= MAX_MAX_MOVES )) || \
                die_cli "--max-movesは${MIN_MAX_MOVES}〜${MAX_MAX_MOVES}の範囲で指定してください"
            MAX_MOVES="$2"
            shift 2
            ;;
        --move-wait)
            (( $# >= 2 )) || die_cli "--move-waitには値が必要です"
            [[ "$2" =~ '^[0-9]+([.][0-9]+)?$' ]] || die_cli "--move-waitは秒数で指定してください"
            typeset -F 6 parsed_move_wait="$2"
            (( parsed_move_wait >= MIN_MOVE_WAIT && parsed_move_wait <= MAX_MOVE_WAIT )) || \
                die_cli "--move-waitは${MIN_MOVE_WAIT}〜${MAX_MOVE_WAIT}秒の範囲で指定してください"
            MOVE_WAIT="$parsed_move_wait"
            shift 2
            ;;
        --help|-h)
            die_cli "--helpは単独で指定してください"
            ;;
        *)
            die_cli "不明なoptionまたは余分な引数です: $1"
            ;;
    esac
done

if [[ "$TARGET_PDF_INPUT" == /* ]]; then
    TARGET_PDF="${TARGET_PDF_INPUT:A}"
else
    TARGET_PDF="$TOOL_DIR/$TARGET_PDF_INPUT"
    TARGET_PDF="${TARGET_PDF:A}"
fi
TARGET_PDF_NAME="${TARGET_PDF:t}"
[[ -n "$TARGET_PDF_NAME" ]] || die_cli "PDFのbasenameを解決できません"

if [[ "$TARGET_PDF_INPUT" == /* ]]; then
    TARGET_PDF_INPUT_SAFE="absolute:<basename:$TARGET_PDF_NAME>"
elif [[ "$TARGET_PDF" == "$TOOL_DIR/"* ]]; then
    TARGET_PDF_INPUT_SAFE="relative:${TARGET_PDF#$TOOL_DIR/}"
else
    TARGET_PDF_INPUT_SAFE="relative-outside:<basename:$TARGET_PDF_NAME>"
fi

if ! /bin/mkdir -p "$OUTPUT_ROOT" 2>/dev/null; then
    /usr/bin/printf '%s\n' "エラー: outputディレクトリを作成できません" >&2
    exit 3
fi

run_timestamp="$(/bin/date '+%Y%m%d-%H%M%S')"
run_dir_name="${TARGET_PDF_NAME}_${run_timestamp}"
candidate_run_dir="$OUTPUT_ROOT/$run_dir_name"

if /bin/mkdir "$candidate_run_dir" 2>/dev/null; then
    RUN_DIR="$candidate_run_dir"
else
    OUTPUT_COLLISION_CANDIDATE="output/$run_dir_name"
    collision_run_dir="$OUTPUT_ROOT/${run_dir_name}_collision_$$"
    if [[ -e "$candidate_run_dir" ]] && /bin/mkdir "$collision_run_dir" 2>/dev/null; then
        RUN_DIR="$collision_run_dir"
        RUN_MODE="OUTPUT_COLLISION_FAILURE"
        stop_reason="output_name_collision"
    else
        /usr/bin/printf '%s\n' "エラー: output実行ディレクトリを作成できません" >&2
        exit 3
    fi
fi

RUN_OUTPUT_RELATIVE="output/${RUN_DIR:t}"
RAW_LOG="$RUN_DIR/raw.log"
EVIDENCE_LOG="$RUN_DIR/evidence.txt"
GROUPING_ERR="$RUN_DIR/.grouping.err"
PREVIEW_ERR="$RUN_DIR/.preview.err"
VOICEOVER_ERR="$RUN_DIR/.voiceover.err"
FRONTMOST_OUT="$RUN_DIR/.frontmost.out"
PAGE_OUT="$RUN_DIR/.page.out"
CURSOR_TEXT_BEFORE="$RUN_DIR/.cursor_text_before"
CURSOR_TEXT_AFTER="$RUN_DIR/.cursor_text_after"
CURSOR_BOUNDS_BEFORE="$RUN_DIR/.cursor_bounds_before"
CURSOR_BOUNDS_AFTER="$RUN_DIR/.cursor_bounds_after"
PHRASE_BEFORE="$RUN_DIR/.phrase_before"
PHRASE_AFTER="$RUN_DIR/.phrase_after"

if ! : > "$RAW_LOG" || ! : > "$EVIDENCE_LOG"; then
    /usr/bin/printf '%s\n' "エラー: outputログを初期化できません" >&2
    exit 3
fi

typeset -F 6 run_started_epoch=$EPOCHREALTIME

replace_literal() {
    local value="$1"
    local needle="$2"
    local replacement="$3"
    local prefix
    local suffix
    if [[ -z "$needle" ]]; then
        /usr/bin/printf '%s' "$value"
        return 0
    fi
    while [[ "$value" == *"$needle"* ]]; do
        prefix="${value%%"$needle"*}"
        suffix="${value#*"$needle"}"
        value="${prefix}${replacement}${suffix}"
    done
    /usr/bin/printf '%s' "$value"
}

redact_for_raw() {
    local value="$1"
    value="$(replace_literal "$value" "$TARGET_PDF" "<TARGET_PDF>")"
    value="$(replace_literal "$value" "$TOOL_DIR" "<TOOL_DIR>")"
    value="$(replace_literal "$value" "$RUN_DIR" "<OUTPUT_DIR>")"
    value="$(/usr/bin/printf '%s' "$value" | /usr/bin/sed -E \
        -e 's#/Users/[^[:cntrl:]]*#<USER_PATH>#g' \
        -e 's#/private/tmp/[^[:cntrl:]]*#<TEMP_PATH>#g' \
        -e 's#/tmp/[^[:cntrl:]]*#<TEMP_PATH>#g' \
        -e 's#/var/folders/[^[:cntrl:]]*#<TEMP_PATH>#g')"
    /usr/bin/printf '%s' "$value"
}

log() {
    local value
    value="$(redact_for_raw "$*")"
    /usr/bin/printf '%s\n' "$value" >> "$RAW_LOG"
}

append_raw_file() {
    local label="$1"
    local path="$2"
    log "$label"
    if [[ -r "$path" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            log "$line"
        done < "$path"
    else
        log "READ_FAILED"
    fi
    log ""
}

append_error_file() {
    append_raw_file "$1" "$2"
}

append_phrase_file() {
    if ! /bin/cat "$1" >> "$EVIDENCE_LOG"; then
        log "EVIDENCE_WRITE_ERROR"
        return 1
    fi
    /usr/bin/printf '\n' >> "$EVIDENCE_LOG"
}

read_grouping_value() {
    : > "$GROUPING_ERR"
    /usr/bin/osascript > "$RUN_DIR/.grouping.out" 2> "$GROUPING_ERR" <<APPLESCRIPT
tell application "$VOICEOVER_UTILITY" to activate
delay 0.5
    tell application "System Events"
        if not (exists process "VoiceOver Utility") then error "VoiceOver Utility process was not found"
        tell process "VoiceOver Utility"
            set elementsToInspect to entire contents of front window
            repeat with anElement in elementsToInspect
                try
                    set candidateRole to (role of anElement as text)
                    set candidateName to (name of anElement as text)
                    if candidateRole is "AXPopUpButton" and ¬
                        (candidateName is "グループ化の動作" or candidateName is "グループ化の動作:") then
                        return (value of anElement as text)
                    end if
                end try
            end repeat
        error "grouping behavior popup was not found"
    end tell
end tell
APPLESCRIPT
    local rc=$?
    if (( rc != 0 )); then
        return "$rc"
    fi
    /bin/cat "$RUN_DIR/.grouping.out"
}

select_voiceover_navigation() {
    : > "$GROUPING_ERR"
    /usr/bin/osascript > /dev/null 2> "$GROUPING_ERR" <<'APPLESCRIPT'
tell application "/System/Applications/Utilities/VoiceOver Utility.app" to activate
tell application "System Events"
    set deadlineDate to (current date) + 10
    set navigationRow to missing value
    set navigationSplitGroup to missing value
    repeat
        if (current date) > deadlineDate then error "VoiceOver Utility navigation preflight timed out"
        if exists process "VoiceOver Utility" then
            tell process "VoiceOver Utility"
                if (count of windows) > 0 then
                    set frontWindow to front window
                    try
                        set splitGroups to every splitter group of frontWindow
                        repeat with splitGroupRef in splitGroups
                            set splitGroupElement to contents of splitGroupRef
                            set scrollAreas to every scroll area of splitGroupElement
                            repeat with scrollAreaRef in scrollAreas
                                set scrollAreaElement to contents of scrollAreaRef
                                set categoryTables to every table of scrollAreaElement
                                repeat with tableRef in categoryTables
                                    set tableElement to contents of tableRef
                                    set tableRole to ""
                                    set tableDescription to ""
                                    try
                                        set tableRole to (role of tableElement as text)
                                        set tableDescription to (description of tableElement as text)
                                    end try
                                    if tableRole is "AXTable" and tableDescription is "ユーティリティのカテゴリ" then
                                        set categoryRows to every row of tableElement
                                        repeat with rowRef in categoryRows
                                            set rowElement to contents of rowRef
                                            set rowCells to every UI element of rowElement
                                            repeat with cellRef in rowCells
                                                set cellElement to contents of cellRef
                                                set cellRole to ""
                                                set candidateName to ""
                                                try
                                                    set cellRole to (role of cellElement as text)
                                                    set candidateName to (name of cellElement as text)
                                                end try
                                                if cellRole is "AXCell" then
                                                    set normalizedName to candidateName
                                                    repeat while (length of normalizedName) > 0 and normalizedName begins with " "
                                                        if (length of normalizedName) is 1 then
                                                            set normalizedName to ""
                                                        else
                                                            set normalizedName to text 2 thru (length of normalizedName) of normalizedName
                                                        end if
                                                    end repeat
                                                    repeat while (length of normalizedName) > 0 and normalizedName ends with " "
                                                        if (length of normalizedName) is 1 then
                                                            set normalizedName to ""
                                                        else
                                                            set normalizedName to text 1 thru ((length of normalizedName) - 1) of normalizedName
                                                        end if
                                                    end repeat
                                                    if normalizedName is "ナビゲーション" then
                                                        set navigationRow to rowElement
                                                        set navigationSplitGroup to splitGroupElement
                                                        exit repeat
                                                    end if
                                                end if
                                            end repeat
                                            if navigationRow is not missing value then exit repeat
                                        end repeat
                                    end if
                                    if navigationRow is not missing value then exit repeat
                                end repeat
                            end repeat
                            if navigationRow is not missing value then exit repeat
                        end repeat
                    end try
                    if navigationRow is not missing value then exit repeat
                end if
            end tell
        end if
        delay 0.2
    end repeat

    try
        set selected of navigationRow to true
        if (selected of navigationRow as boolean) is not true then error "navigation row was not selected"
    on error selectionError
        error "navigation row selection failed: " & selectionError
    end try

    repeat
        if (current date) > deadlineDate then error "grouping behavior popup was not found within 10 seconds"
        try
            tell process "VoiceOver Utility"
                set groupingButtons to every pop up button of navigationSplitGroup
                repeat with popupRef in groupingButtons
                    set popupElement to contents of popupRef
                    set candidateRole to (role of popupElement as text)
                    set candidateName to (name of popupElement as text)
                    if candidateRole is "AXPopUpButton" and ¬
                        (candidateName is "グループ化の動作" or candidateName is "グループ化の動作:") then
                        return
                    end if
                end repeat
            end tell
        end try
        delay 0.2
    end repeat
end tell
APPLESCRIPT
}

close_target_preview_window() {
    : > "$PREVIEW_ERR"
    /usr/bin/osascript - "$TARGET_PDF" 2> "$PREVIEW_ERR" <<'APPLESCRIPT'
on run argv
    set targetPath to item 1 of argv
    tell application "/System/Applications/Preview.app"
        set matchingDocuments to {}
        repeat with aDocument in documents
            set documentPath to POSIX path of (path of aDocument)
            if documentPath is targetPath then
                set isModified to modified of aDocument
                if isModified is true then
                    error "target Preview document is modified; refusing to close it"
                end if
                set end of matchingDocuments to aDocument
            end if
        end repeat
        set closedCount to 0
        repeat with aDocument in matchingDocuments
            close contents of aDocument
            set closedCount to closedCount + 1
        end repeat
        return closedCount
    end tell
end run
APPLESCRIPT
}

check_preview_target() {
    : > "$PREVIEW_ERR"
    /usr/bin/osascript - "$TARGET_PDF" > "$FRONTMOST_OUT" 2> "$PREVIEW_ERR" <<'APPLESCRIPT'
on run argv
    set targetPath to item 1 of argv
    tell application "System Events"
        set frontName to name of first application process whose frontmost is true
    end tell
    if frontName is not "Preview" then error "frontmost application is not Preview"
    tell application "/System/Applications/Preview.app"
        if (count of documents) is 0 then error "Preview has no open document"
        set frontPath to POSIX path of (get path of front document)
    end tell
    if frontPath is not targetPath then error "front Preview document does not match target PDF"
    return frontName & return & "TARGET_DOCUMENT_MATCH=YES"
end run
APPLESCRIPT
}

open_and_activate_preview() {
    : > "$PREVIEW_ERR"
    if ! /usr/bin/open -a "/System/Applications/Preview.app" "$TARGET_PDF" 2> "$PREVIEW_ERR"; then
        return 1
    fi
    local attempt
    for (( attempt = 1; attempt <= 6; attempt++ )); do
        /bin/sleep 0.5
        if check_preview_target; then
            return 0
        fi
    done
    return 1
}

read_preview_page() {
    : > "$PAGE_OUT"
    : > "$PREVIEW_ERR"
    /usr/bin/osascript > "$PAGE_OUT" 2> "$PREVIEW_ERR" <<'APPLESCRIPT'
tell application "System Events"
    tell process "Preview"
        set elementsToInspect to entire contents of front window
        repeat with anElement in elementsToInspect
            try
                if (role of anElement) is "AXStaticText" then
                    set candidateValue to value of anElement as text
                    if candidateValue begins with "1 / " and candidateValue ends with " ページ" then
                        return candidateValue
                    end if
                end if
            end try
        end repeat
        error "Preview page indicator was not found"
    end tell
end tell
APPLESCRIPT
}

read_cursor_text() {
    local output_path="$1"
    : > "$output_path"
    : > "$VOICEOVER_ERR"
    /usr/bin/osascript > "$output_path" 2> "$VOICEOVER_ERR" <<'APPLESCRIPT'
tell application "/System/Library/CoreServices/VoiceOver.app"
    tell vo cursor
        return text under cursor
    end tell
end tell
APPLESCRIPT
}

read_cursor_bounds() {
    local output_path="$1"
    : > "$output_path"
    : > "$VOICEOVER_ERR"
    /usr/bin/osascript > "$output_path" 2> "$VOICEOVER_ERR" <<'APPLESCRIPT'
tell application "/System/Library/CoreServices/VoiceOver.app"
    tell vo cursor
        return bounds
    end tell
end tell
APPLESCRIPT
}

read_phrase() {
    local output_path="$1"
    : > "$output_path"
    : > "$VOICEOVER_ERR"
    /usr/bin/osascript > "$output_path" 2> "$VOICEOVER_ERR" <<'APPLESCRIPT'
tell application "/System/Library/CoreServices/VoiceOver.app"
    return content of last phrase
end tell
APPLESCRIPT
}

move_right() {
    : > "$VOICEOVER_ERR"
    /usr/bin/osascript 2> "$VOICEOVER_ERR" <<'APPLESCRIPT'
tell application "/System/Library/CoreServices/VoiceOver.app"
    tell vo cursor
        move right
    end tell
end tell
APPLESCRIPT
}

parse_bounds() {
    local raw="$1"
    raw="${raw//$'\r'/}"
    raw="${raw//$'\n'/}"
    raw="${raw//\{/}"
    raw="${raw//\}/}"
    if [[ "$raw" =~ '^(-?[0-9]+),[[:space:]]*(-?[0-9]+),[[:space:]]*([1-9][0-9]*),[[:space:]]*([1-9][0-9]*)$' ]]; then
        PARSED_X="${match[1]}"
        PARSED_Y="${match[2]}"
        PARSED_W="${match[3]}"
        PARSED_H="${match[4]}"
        return 0
    fi
    return 1
}

bounds_contained() {
    local child_left="$1"
    local child_top="$2"
    local child_right="$3"
    local child_bottom="$4"
    (( child_left >= GROUP_X && child_top >= GROUP_Y && child_right <= GROUP_W && child_bottom <= GROUP_H ))
}

on_exit() {
    local rc="$1"
    trap - EXIT

    if (( grouping_read == 1 )); then
        if grouping_after="$(read_grouping_value)"; then
            log "VOICEOVER_GROUPING_AFTER: $grouping_after"
            if [[ "$grouping_after" == "$grouping_before" ]]; then
                log "GROUPING_MATCH_AFTER_RUN: YES"
            else
                log "GROUPING_MATCH_AFTER_RUN: NO"
                if (( rc == 0 )); then
                    rc=30
                    stop_reason="grouping_changed_after_run"
                fi
            fi
        else
            log "VOICEOVER_GROUPING_AFTER: READ_FAILED"
            append_error_file "VOICEOVER_GROUPING_AFTER_ERROR:" "$GROUPING_ERR"
            log "GROUPING_MATCH_AFTER_RUN: NO"
            if (( rc == 0 )); then
                rc=31
                stop_reason="grouping_after_read_failed"
            fi
        fi
    else
        log "VOICEOVER_GROUPING_AFTER: NO_SNAPSHOT"
        log "GROUPING_MATCH_AFTER_RUN: NO"
    fi

    if (( run_started_epoch > 0 )); then
        typeset -F 6 run_completed_epoch=$EPOCHREALTIME
        typeset -F 6 run_elapsed=$(( run_completed_epoch - run_started_epoch ))
    else
        typeset -F 6 run_elapsed=0
    fi

    log "STOP_REASON: $stop_reason"
    log "RUN_TIMESTAMP: $(/bin/date '+%Y-%m-%dT%H:%M:%S%z')"
    log "TOOL_VERSION: $TOOL_VERSION"
    log "RUN_MODE: $RUN_MODE"
    log "TARGET_PDF_NAME: $TARGET_PDF_NAME"
    log "TARGET_PDF_INPUT: $TARGET_PDF_INPUT_SAFE"
    log "OUTPUT_DIRECTORY: $RUN_OUTPUT_RELATIVE"
    log "PREVIEW_START_PAGE: $preview_start_page"
    log "PREVIEW_TOTAL_PAGES: $preview_total_pages"
    log "PDF_REGION_BOUNDS: $document_group_bounds"
    log "EOF_REASON: $eof_reason"
    log "TOTAL_MOVES: $total_moves"
    log "EVIDENCE_ITEMS_RECORDED: $evidence_items_count"
    log "ELAPSED_SECONDS: $(printf '%0.3f' "$run_elapsed")"
    log "VOICEOVER_SETTINGS_WRITE: NOT_PERFORMED"
    log "PERMISSION_DIALOG_AUTOMATION: NOT_PERFORMED"
    log "EVIDENCE_OUTPUT: $RUN_OUTPUT_RELATIVE/evidence.txt"
    log "EOF_DETECTED: $eof_detected"
    log "EXIT_STATUS: $rc"

    /bin/rm -f "$GROUPING_ERR" "$RUN_DIR/.grouping.out" \
        "$PREVIEW_ERR" "$VOICEOVER_ERR" "$FRONTMOST_OUT" "$PAGE_OUT" \
        "$CURSOR_TEXT_BEFORE" "$CURSOR_TEXT_AFTER" "$CURSOR_BOUNDS_BEFORE" \
        "$CURSOR_BOUNDS_AFTER" "$PHRASE_BEFORE" "$PHRASE_AFTER"
    /usr/bin/printf '%s\n' \
        "EVIDENCE_OUTPUT: $RUN_OUTPUT_RELATIVE/evidence.txt" \
        "RAW_LOG_OUTPUT: $RUN_OUTPUT_RELATIVE/raw.log" \
        "EOF_DETECTED: $eof_detected" \
        "EXIT_STATUS: $rc"
    exit "$rc"
}

trap 'on_exit $?' EXIT

log "START"
log "RUN_TIMESTAMP: $(/bin/date '+%Y-%m-%dT%H:%M:%S%z')"
log "TOOL_VERSION: $TOOL_VERSION"
log "RUN_MODE: $RUN_MODE"
log "TARGET_PDF_NAME: $TARGET_PDF_NAME"
log "TARGET_PDF_INPUT: $TARGET_PDF_INPUT_SAFE"
log "OUTPUT_DIRECTORY: $RUN_OUTPUT_RELATIVE"
log "MAX_MOVES: $MAX_MOVES"
log "MOVE_WAIT_SECONDS: $(printf '%0.3f' "$MOVE_WAIT")"
log "PREVIEW_WINDOW_POLICY: CLOSE_TARGET_ONLY_IF_UNMODIFIED_THEN_OPEN"
log "VOICEOVER_SETTINGS_WRITE: NOT_PERFORMED"
log "PERMISSION_DIALOG_AUTOMATION: NOT_PERFORMED"

if [[ "$RUN_MODE" == "OUTPUT_COLLISION_FAILURE" ]]; then
    log "OUTPUT_COLLISION_CANDIDATE: $OUTPUT_COLLISION_CANDIDATE"
    log "SCAN_STARTED: NO"
    exit 40
fi

if [[ ! -f "$TARGET_PDF" ]]; then
    stop_reason="target_pdf_missing"
    log "SCAN_STARTED: NO"
    exit 10
fi

: > "$GROUPING_ERR"
if ! select_voiceover_navigation; then
    log "VOICEOVER_NAVIGATION_ROW_SELECTED: NO"
    append_error_file "VOICEOVER_NAVIGATION_SELECTION_ERROR:" "$GROUPING_ERR"
    stop_reason="voiceover_navigation_selection_failed"
    log "SCAN_STARTED: NO"
    exit 13
fi
log "VOICEOVER_NAVIGATION_ROW_SELECTED: YES"
if ! grouping_before="$(read_grouping_value)"; then
    append_error_file "VOICEOVER_GROUPING_BEFORE_ERROR:" "$GROUPING_ERR"
    stop_reason="grouping_read_failed"
    log "SCAN_STARTED: NO"
    exit 13
fi
grouping_read=1
log "VOICEOVER_GROUPING_BEFORE: $grouping_before"
if [[ "$grouping_before" != "$GROUPING_REQUIRED" ]]; then
    log "GROUPING_REQUIRED: $GROUPING_REQUIRED"
    stop_reason="grouping_value_not_required"
    log "SCAN_STARTED: NO"
    exit 14
fi

if ! close_count="$(close_target_preview_window)"; then
    append_error_file "PREVIEW_CLOSE_ERROR:" "$PREVIEW_ERR"
    stop_reason="close_target_preview_failed"
    log "SCAN_STARTED: NO"
    exit 15
fi
log "CLOSE_TARGET_PREVIEW_DOCUMENTS: $close_count"

if ! open_and_activate_preview; then
    append_error_file "OPEN_OR_PREVIEW_TARGET_ERROR:" "$PREVIEW_ERR"
    stop_reason="open_or_target_preview_failed"
    log "SCAN_STARTED: NO"
    exit 16
fi
log "PREVIEW_TARGET_CHECK: PASS"

if ! read_preview_page; then
    append_error_file "PREVIEW_PAGE_ERROR:" "$PREVIEW_ERR"
    stop_reason="preview_page_read_failed"
    log "SCAN_STARTED: NO"
    exit 17
fi
preview_start_page="$(/bin/cat "$PAGE_OUT")"
preview_start_page="${preview_start_page//$'\\r'/}"
if [[ "$preview_start_page" =~ '^1 / ([1-9][0-9]*) ページ$' ]]; then
    preview_total_pages="${match[1]}"
    log "PREVIEW_PAGE_CHECK: PASS"
else
    log "PREVIEW_PAGE_CHECK: FAIL"
    stop_reason="preview_did_not_start_at_page_1"
    exit 18
fi

if ! read_cursor_text "$CURSOR_TEXT_BEFORE" || \
   ! read_cursor_bounds "$CURSOR_BOUNDS_BEFORE" || \
   ! read_phrase "$PHRASE_BEFORE"; then
    append_error_file "INITIAL_VOICEOVER_READ_ERROR:" "$VOICEOVER_ERR"
    stop_reason="initial_voiceover_read_failed"
    exit 19
fi
initial_cursor_text="$(/bin/cat "$CURSOR_TEXT_BEFORE")"
if [[ "$initial_cursor_text" != "書類 グループ" ]]; then
    append_raw_file "INITIAL_CURSOR_TEXT:" "$CURSOR_TEXT_BEFORE"
    stop_reason="initial_cursor_was_not_preview_document_group"
    exit 20
fi
if ! parse_bounds "$(/bin/cat "$CURSOR_BOUNDS_BEFORE")"; then
    append_raw_file "INITIAL_CURSOR_BOUNDS:" "$CURSOR_BOUNDS_BEFORE"
    stop_reason="initial_cursor_bounds_unreadable"
    exit 21
fi
GROUP_X="$PARSED_X"
GROUP_Y="$PARSED_Y"
GROUP_W="$PARSED_W"
GROUP_H="$PARSED_H"
document_group_bounds="$GROUP_X,$GROUP_Y,$GROUP_W,$GROUP_H"
log "INITIAL_CURSOR_TEXT: $initial_cursor_text"
log "INITIAL_CURSOR_BOUNDS: $document_group_bounds"
log "INITIAL_PREVIEW_DOCUMENT_GROUP: PASS"
log "SCAN_STARTED: YES"

typeset -F 6 run_started_epoch=$EPOCHREALTIME
for (( move_number = 1; move_number <= MAX_MOVES; move_number++ )); do
    if ! check_preview_target; then
        append_error_file "PRE_MOVE_PREVIEW_TARGET_ERROR_$move_number:" "$PREVIEW_ERR"
        stop_reason="preview_target_changed_before_move_${move_number}"
        exit 22
    fi
    log "[MOVE $(printf '%03d' "$move_number")]"
    log "PRE_MOVE_PREVIEW_TARGET_CHECK: PASS"
    typeset -F 6 move_start_epoch=$EPOCHREALTIME
    total_moves=$move_number
    if ! move_right; then
        append_error_file "MOVE_RIGHT_ERROR_$move_number:" "$VOICEOVER_ERR"
        stop_reason="move_right_failed_at_${move_number}"
        exit 23
    fi
    /bin/sleep "$MOVE_WAIT"
    if ! read_cursor_text "$CURSOR_TEXT_AFTER" || \
       ! read_cursor_bounds "$CURSOR_BOUNDS_AFTER" || \
       ! read_phrase "$PHRASE_AFTER"; then
        append_error_file "POST_MOVE_VOICEOVER_READ_ERROR_$move_number:" "$VOICEOVER_ERR"
        stop_reason="voiceover_read_failed_at_${move_number}"
        exit 24
    fi
    typeset -F 6 phrase_ready_epoch=$EPOCHREALTIME
    typeset -F 6 phrase_ready=$(( phrase_ready_epoch - run_started_epoch ))
    typeset -F 6 latency=$(( phrase_ready_epoch - move_start_epoch ))

    if ! check_preview_target; then
        append_raw_file "AFTER_MOVE_PHRASE_BEFORE_STOP:" "$PHRASE_AFTER"
        append_error_file "POST_MOVE_PREVIEW_TARGET_ERROR_$move_number:" "$PREVIEW_ERR"
        stop_reason="preview_target_changed_after_move_${move_number}"
        exit 25
    fi

    phrase_updated="YES"
    if /usr/bin/cmp -s "$PHRASE_BEFORE" "$PHRASE_AFTER"; then
        phrase_updated="NO"
    fi
    cursor_changed="YES"
    if /usr/bin/cmp -s "$CURSOR_TEXT_BEFORE" "$CURSOR_TEXT_AFTER" && \
       /usr/bin/cmp -s "$CURSOR_BOUNDS_BEFORE" "$CURSOR_BOUNDS_AFTER"; then
        cursor_changed="NO"
    fi

    if ! parse_bounds "$(/bin/cat "$CURSOR_BOUNDS_AFTER")"; then
        append_raw_file "AFTER_CURSOR_BOUNDS:" "$CURSOR_BOUNDS_AFTER"
        stop_reason="cursor_bounds_unreadable_at_${move_number}"
        exit 26
    fi
    cursor_x="$PARSED_X"
    cursor_y="$PARSED_Y"
    cursor_w="$PARSED_W"
    cursor_h="$PARSED_H"
    cursor_in_pdf="NO"
    if bounds_contained "$cursor_x" "$cursor_y" "$cursor_w" "$cursor_h"; then
        cursor_in_pdf="YES"
    fi

    if [[ "$phrase_updated" == "NO" && "$cursor_changed" == "NO" ]]; then
        eof_same_streak=$(( eof_same_streak + 1 ))
    else
        eof_same_streak=0
    fi
    eof_candidate="NO"
    if (( eof_same_streak >= 2 )); then
        eof_candidate="YES"
        eof_detected="YES"
        eof_reason="cursor_state_unchanged_and_phrase_not_updated_twice"
    fi

    typeset -F 6 move_elapsed=$(( phrase_ready_epoch - run_started_epoch ))
    log "MOVE_ELAPSED_SECONDS: $(printf '%0.3f' "$move_elapsed")"
    log "MOVE_LATENCY_SECONDS: $(printf '%0.3f' "$latency")"
    append_raw_file "CURSOR_TEXT_BEFORE:" "$CURSOR_TEXT_BEFORE"
    append_raw_file "CURSOR_BOUNDS_BEFORE:" "$CURSOR_BOUNDS_BEFORE"
    append_raw_file "CURSOR_TEXT_AFTER:" "$CURSOR_TEXT_AFTER"
    append_raw_file "CURSOR_BOUNDS_AFTER:" "$CURSOR_BOUNDS_AFTER"
    append_raw_file "PHRASE:" "$PHRASE_AFTER"
    log "PHRASE_UPDATED: $phrase_updated"
    log "CURSOR_CHANGED: $cursor_changed"
    log "CURSOR_IN_PDF_REGION: $cursor_in_pdf"
    log "EOF_STREAK: $eof_same_streak"
    log "EOF_CANDIDATE: $eof_candidate"
    evidence_appended="NO"

    if [[ "$cursor_in_pdf" != "YES" ]]; then
        log "EVIDENCE_APPENDED: NO"
        stop_reason="pdf_region_exit_at_${move_number}"
        exit 27
    fi
    if [[ "$cursor_changed" == "YES" ]]; then
        if ! append_phrase_file "$PHRASE_AFTER"; then
            stop_reason="evidence_write_failed_at_${move_number}"
            exit 28
        fi
        evidence_items_count=$(( evidence_items_count + 1 ))
        evidence_appended="YES"
    fi
    log "EVIDENCE_APPENDED: $evidence_appended"

    /bin/cp "$CURSOR_TEXT_AFTER" "$CURSOR_TEXT_BEFORE"
    /bin/cp "$CURSOR_BOUNDS_AFTER" "$CURSOR_BOUNDS_BEFORE"
    /bin/cp "$PHRASE_AFTER" "$PHRASE_BEFORE"

    if [[ "$eof_candidate" == "YES" ]]; then
        stop_reason="eof_detected"
        break
    fi
done

if [[ "$eof_detected" != "YES" ]]; then
    stop_reason="max_moves_reached_without_eof"
    exit 29
fi

exit 0
