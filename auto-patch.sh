#!/bin/bash
# ===========================================================
# DeepFlow 自动补丁升级脚本（无锁版，优化 MD 覆盖 & 摘要）
# 功能概览：
#  - OSS 自动检测最新 x86_64 补丁包并下载
#  - 下载对应 .md 并智能提取“更新内容”（最后20行）
#  - 自动覆盖 .md 文件，无需人工确认
#  - 备份 values 与 values-custom
#  - 检查磁盘空间
#  - 非交互式执行 deepflow-patch（选择模式 2）
#  - 飞书卡片通知（交互卡片，包含更新内容 + 链接）
# ===========================================================

set -euo pipefail

# -------------------------
# 可配置项
# -------------------------
OSS_URI="oss://df-patch-no-delete/patch/6.6/6.6.9/latest"
PATCH_NOTE_HTTP_BASE="https://oss.deepflow.local/patch/6.6/6.6.9/latest"
LOCAL_DIR="/root"
TMP_DIR="/root/.patch_tmp"
BACKUP_DIR="/root/patch_backups"
STATE_FILE="/var/lib/deepflow_patch_last"
LOG="/var/log/deepflow_patch_auto.log"
OSSUTIL="$(command -v ossutil || echo /usr/local/bin/ossutil)"
DEEPFLOW_PATCH="/usr/local/deepflow/bin/deepflow-patch"
VALUES_CUSTOM="/usr/local/deepflow/templates/values-custom.yaml"
VALUES="/usr/local/deepflow/templates/values.yaml"
WEBHOOK_URL="https://open.feishu.cn/open-apis/bot/v2/hook/9903763d-1033-49c2-ad60-a710d6d840f1"
RETRY=2
MIN_AVAIL_KB=$((5 * 1024 * 1024))

mkdir -p "$TMP_DIR" "$BACKUP_DIR" "$(dirname "$STATE_FILE")" "$(dirname "$LOG")"

# -------------------------
# 日志函数
# -------------------------
log() {
  echo "$(date '+%F %T') $*" | tee -a "$LOG" || true
}

# -------------------------
# 飞书卡片函数
# -------------------------
send_feishu_card() {
  local status="$1"; shift
  local title="$1"; shift
  local short_msg="$1"; shift
  local patch_name="$1"; shift
  local start_time="$1"; shift
  local env_ip="$1"; shift
  local log_path="$1"; shift
  local patch_note_url="$1"; shift
  local update_content="$1"; shift

  local end_time
  end_time="$(date '+%F %T')"

  local template icon
  case "$status" in
    success) template="green"; icon="✅";;
    failed)  template="red";   icon="❌";;
    skip)    template="orange";icon="⚠️";;
    info)    template="blue";  icon="ℹ️";;
    *)       template="gray";  icon="ℹ️";;
  esac

  local card_json
  card_json=$(cat <<EOF
{
  "msg_type": "interactive",
  "card": {
    "header": {
      "template": "${template}",
      "title": { "tag": "plain_text", "content": "${icon} DeepFlow 自动补丁：${title}" }
    },
    "elements": [
      { "tag": "div", "text": { "tag": "lark_md", "content": "${short_msg}" } },
      { "tag": "hr" },
      { "tag": "div", "text": { "tag": "lark_md", "content": "**开始时间：** ${start_time}\n**结束时间：** ${end_time}\n**升级环境（主机IP）：** ${env_ip}\n**当前补丁包：** ${patch_name}\n**日志路径：** ${log_path}" } },
      { "tag": "hr" },
      { "tag": "div", "text": { "tag": "lark_md", "content": "**更新内容（摘录）：**\n${update_content}" } },
      { "tag": "action", "actions": [ { "tag": "button", "text": { "tag": "plain_text", "content": "📄 查看完整更新说明" }, "url": "${patch_note_url}", "type": "default" } ] }
    ]
  }
}
EOF
)

  curl -s -X POST -H "Content-Type: application/json" -d "$card_json" "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

# -------------------------
# 主流程开始
# -------------------------
START_TIME="$(date '+%F %T')"
log "========== DeepFlow 自动补丁开始 (${START_TIME}) =========="

# 基本校验
[ -x "$OSSUTIL" ] || { log "未找到 ossutil"; exit 1; }
[ -x "$DEEPFLOW_PATCH" ] || { log "未找到 deepflow-patch"; exit 1; }

# 磁盘空间检查
avail_kb=$(df --output=avail -k "$LOCAL_DIR" | tail -n1 | tr -d ' ' || echo 0)
if [ "$avail_kb" -lt "$MIN_AVAIL_KB" ]; then
  log "磁盘空间不足：${avail_kb}KB < ${MIN_AVAIL_KB}KB"
  exit 1
fi

# 查找最新补丁
log "查询 OSS 最新补丁：$OSS_URI"
latest_obj=$("$OSSUTIL" ls "${OSS_URI}/" 2>/dev/null | awk '{print $NF}' | sed 's|.*/||' | grep 'ALL\.tar\.gz$' | sort -V | tail -n1 || true)
if [ -z "$latest_obj" ]; then
  msg="未找到 x86_64 补丁"
  log "$msg"
  send_feishu_card "info" "无可用补丁" "$msg" "-" "$START_TIME" "$(hostname -I | awk '{print $1}')" "$LOG" "-"
  exit 0
fi

log "发现补丁包：$latest_obj"

# 检查是否已应用
prev="$(cat "$STATE_FILE" 2>/dev/null || true)"
if [ "$latest_obj" = "$prev" ]; then
  msg="补丁 $latest_obj 已应用过，跳过"
  log "$msg"
  send_feishu_card "info" "无需更新" "$msg" "$latest_obj" "$START_TIME" "$(hostname -I | awk '{print $1}')" "$LOG" "${PATCH_NOTE_HTTP_BASE}/${latest_obj%.tar.gz}.md"
  exit 0
fi

# 下载补丁
tmp_patch="$TMP_DIR/$latest_obj.part"
final_patch="$LOCAL_DIR/$latest_obj"
md_name="${latest_obj%.tar.gz}.md"
tmp_md="$TMP_DIR/$md_name"

download_ok=0
for i in $(seq 1 $RETRY); do
  log "下载补丁（尝试 $i）: ${OSS_URI}/${latest_obj}"
  if "$OSSUTIL" cp "${OSS_URI}/${latest_obj}" "$tmp_patch" 2>&1 | tee -a "$LOG"; then
    mv -f "$tmp_patch" "$final_patch"
    download_ok=1
    log "补丁下载完成： $final_patch"
    break
  else
    log "下载失败（第 $i 次），2秒后重试..."
    sleep 2
  fi
done

[ "$download_ok" -eq 1 ] || { msg="补丁下载失败"; log "$msg"; send_feishu_card "failed" "下载失败" "$msg" "$latest_obj" "$START_TIME" "$(hostname -I | awk '{print $1}')" "$LOG" "${PATCH_NOTE_HTTP_BASE}/${latest_obj%.tar.gz}.md" "无"; exit 1; }

# 下载 md（非致命，强制覆盖）
if "$OSSUTIL" cp "${OSS_URI}/${md_name}" "$tmp_md" --force 2>/dev/null | tee -a "$LOG"; then
  log "说明文件已下载： $tmp_md"
else
  log "说明文件不存在或下载失败： ${OSS_URI}/${md_name}（可忽略）"
fi
# 提取更新内容（最后20行）
update_content_raw=""
patch_id="$(echo "$latest_obj" | awk -F'-' '{print $1}')"

if [ -f "$tmp_md" ]; then
  patch_section=$(awk '/\[PATCH说明\]/{flag=1; next}/\[验证方法\]/{flag=0} flag' "$tmp_md" | sed 's/^[ \t]*//;s/[ \t]*$//' | sed '/^$/d' || true)
  if [ -n "$patch_section" ]; then
    update_content_raw=$(echo "$patch_section" | tail -n 20)
  else
    patch_block=$(awk -v id="$patch_id" 'BEGIN{flag=0} /^[0-9]+-/{if($1 ~ ("^"id"-")) {flag=1; next} else if(flag) exit} flag && NF {print}' "$tmp_md" | sed 's/^[ \t]*//;s/[ \t]*$//' | sed '/^$/d' || true)
    if [ -n "$patch_block" ]; then
      update_content_raw=$(echo "$patch_block" | tail -n 20)
    else
      update_content_raw=$(grep -E '^-|^[[:space:]]+-' "$tmp_md" | sed 's/^[ \t]*//' | tail -n 20 || true)
    fi
  fi
else
  update_content_raw="未找到说明文件：${md_name}"
fi

update_content="$(echo "$update_content_raw" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')"
[ -n "$update_content" ] || update_content="未能从说明文件中提取到更新内容。"

# 备份 values 文件
ts="$(date '+%Y%m%d%H%M%S')"
for f in "$VALUES_CUSTOM" "$VALUES"; do
  [ -f "$f" ] && cp -a "$f" "$BACKUP_DIR/$(basename "$f").$ts" && log "已备份配置： $f -> $BACKUP_DIR/$(basename "$f").$ts"
done

# 执行补丁
log "开始执行 deepflow-patch（模式2）..."
PATCH_NOTE_URL="${PATCH_NOTE_HTTP_BASE}/${md_name}"
if printf "2\n" | "$DEEPFLOW_PATCH" -a "$final_patch" 2>&1 | tee -a "$LOG"; then
  log "补丁 ${latest_obj} 执行成功"
  echo "$latest_obj" > "$STATE_FILE"
  send_feishu_card "success" "补丁成功" "补丁已成功应用，备份时间：${ts}" "$latest_obj" "$START_TIME" "$(hostname -I | awk '{print $1}')" "$LOG" "$PATCH_NOTE_URL" "$update_content"
  exit 0
else
  log "补丁 ${latest_obj} 执行失败，请查看日志： $LOG"
  send_feishu_card "failed" "补丁失败" "补丁执行失败，请登录主机查看日志：${LOG}" "$latest_obj" "$START_TIME" "$(hostname -I | awk '{print $1}')" "$LOG" "$PATCH_NOTE_URL" "$update_content"
  exit 1
fi

