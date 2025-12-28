#!/bin/bash
# 火山引擎录音文件识别服务
# 用于将音频文件转换为文字稿
#
# 使用方法：
#     ./transcribe.sh <音频文件路径>
#
# 支持的音频格式：mp3, m4a, wav, ogg
#
# 注意：此脚本会启动一个临时的本地 HTTP 服务器来提供文件访问
# 需要确保本机有公网 IP 且对应端口可访问

set -e

# 火山引擎 API 配置
VOLCENGINE_APP_ID="2505335848"
VOLCENGINE_ACCESS_TOKEN="sHrVzn0mOgUbUF2Dvu-h17H7czytWk6i"

# API 端点
SUBMIT_URL="https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"
QUERY_URL="https://openspeech.bytedance.com/api/v3/auc/bigmodel/query"

# 资源 ID(使用豆包录音文件识别模型2.0)
RESOURCE_ID="volc.seedasr.auc"

# 本地 HTTP 服务器配置
HTTP_PORT=18080  # 使用高端口避免权限问题

# 轮询配置
POLL_INTERVAL=5
MAX_POLL_COUNT=720  # 最多等待 1 小时

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 全局变量
HTTP_SERVER_PID=""

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 清理函数
cleanup() {
    if [ -n "$HTTP_SERVER_PID" ] && kill -0 "$HTTP_SERVER_PID" 2>/dev/null; then
        log_info "正在关闭 HTTP 服务器..."
        kill "$HTTP_SERVER_PID" 2>/dev/null || true
        wait "$HTTP_SERVER_PID" 2>/dev/null || true
    fi
}

# 注册清理函数
trap cleanup EXIT INT TERM

# 获取公网 IP
get_public_ip() {
    # 尝试获取 IPv4
    local ipv4=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || curl -4 -s --connect-timeout 5 icanhazip.com 2>/dev/null || echo "")
    
    if [ -n "$ipv4" ]; then
        echo "$ipv4"
        return 0
    fi
    
    # 尝试获取 IPv6
    local ipv6=$(curl -6 -s --connect-timeout 5 ifconfig.me 2>/dev/null || curl -6 -s --connect-timeout 5 icanhazip.com 2>/dev/null || echo "")
    
    if [ -n "$ipv6" ]; then
        echo "[$ipv6]"  # IPv6 需要用方括号包围
        return 0
    fi
    
    return 1
}

# 获取音频格式
get_audio_format() {
    local file_path="$1"
    local ext="${file_path##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    
    case "$ext" in
        mp3|m4a) echo "mp3" ;;
        wav) echo "wav" ;;
        ogg) echo "ogg" ;;
        *) echo "mp3" ;;
    esac
}

# 启动本地 HTTP 服务器
start_http_server() {
    local file_dir="$1"
    
    log_info "正在启动本地 HTTP 服务器 (端口: $HTTP_PORT)..."
    
    # 使用 Python 启动简单 HTTP 服务器
    cd "$file_dir"
    python3 -m http.server $HTTP_PORT --bind 0.0.0.0 >/dev/null 2>&1 &
    HTTP_SERVER_PID=$!
    cd - >/dev/null
    
    # 等待服务器启动
    sleep 2
    
    # 检查服务器是否成功启动
    if ! kill -0 "$HTTP_SERVER_PID" 2>/dev/null; then
        log_error "HTTP 服务器启动失败"
        return 1
    fi
    
    log_info "HTTP 服务器已启动 (PID: $HTTP_SERVER_PID)"
    return 0
}

# 生成文件访问 URL
generate_file_url() {
    local file_name="$1"
    local public_ip="$2"
    
    # URL 编码文件名
    local encoded_name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$file_name'))")
    
    echo "http://${public_ip}:${HTTP_PORT}/${encoded_name}"
}

# 提交转写任务
submit_task() {
    local audio_url="$1"
    local audio_format="$2"
    local request_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    
    log_info "正在提交转写任务..."
    log_info "Request ID: $request_id"
    log_info "Audio URL: $audio_url"
    
    local payload=$(cat <<EOF
{
    "user": {
        "uid": "weekly-report-transcription"
    },
    "audio": {
        "format": "$audio_format",
        "url": "$audio_url"
    },
    "request": {
        "model_name": "bigmodel",
        "enable_itn": true,
        "enable_punc": true,
        "enable_ddc": true,
        "show_utterances": true,
        "enable_speaker_info": true
    }
}
EOF
)
    
    local response=$(curl -s -i -X POST "$SUBMIT_URL" \
        -H "Content-Type: application/json" \
        -H "X-Api-App-Key: $VOLCENGINE_APP_ID" \
        -H "X-Api-Access-Key: $VOLCENGINE_ACCESS_TOKEN" \
        -H "X-Api-Resource-Id: $RESOURCE_ID" \
        -H "X-Api-Request-Id: $request_id" \
        -H "X-Api-Sequence: -1" \
        -d "$payload")
    
    # 解析响应头
    local status_code=$(echo "$response" | grep -i "^X-Api-Status-Code:" | sed 's/.*: *//' | tr -d '\r\n')
    local message=$(echo "$response" | grep -i "^X-Api-Message:" | sed 's/.*: *//' | tr -d '\r\n')
    
    log_info "API 响应状态: $status_code - $message"
    
    if [ "$status_code" = "20000000" ]; then
        log_info "任务提交成功！"
        echo "$request_id"
        return 0
    else
        log_error "任务提交失败: $message (code: $status_code)"
        return 1
    fi
}

# 查询转写结果
query_result() {
    local request_id="$1"
    
    local response=$(curl -s -i -X POST "$QUERY_URL" \
        -H "Content-Type: application/json" \
        -H "X-Api-App-Key: $VOLCENGINE_APP_ID" \
        -H "X-Api-Access-Key: $VOLCENGINE_ACCESS_TOKEN" \
        -H "X-Api-Resource-Id: $RESOURCE_ID" \
        -H "X-Api-Request-Id: $request_id" \
        -d '{}')
    
    # 分离响应头和响应体
    local headers=$(echo "$response" | sed -n '1,/^\r*$/p')
    local body=$(echo "$response" | sed '1,/^\r*$/d')
    
    local status_code=$(echo "$headers" | grep -i "^X-Api-Status-Code:" | sed 's/.*: *//' | tr -d '\r\n')
    
    case "$status_code" in
        20000000)
            echo "success"
            echo "$body"
            return 0
            ;;
        20000001|20000002)
            echo "processing"
            return 0
            ;;
        20000003)
            echo "silent"
            return 0
            ;;
        *)
            echo "error:$status_code"
            return 0
            ;;
    esac
}

# 等待转写完成
wait_for_result() {
    local request_id="$1"
    local output_file="$2"
    local count=0
    
    log_info "等待转写完成..."
    
    while [ $count -lt $MAX_POLL_COUNT ]; do
        local result=$(query_result "$request_id")
        local status=$(echo "$result" | head -1)
        
        case "$status" in
            success)
                echo ""
                log_info "转写完成！"
                # 提取 JSON 结果（跳过第一行状态）
                echo "$result" | tail -n +2 > "$output_file.json"
                return 0
                ;;
            processing)
                printf "\r处理中... ($((count * POLL_INTERVAL))秒)    "
                ;;
            silent)
                echo ""
                log_error "音频为静音，没有可识别的内容"
                return 1
                ;;
            error:*)
                echo ""
                log_error "转写失败: $status"
                return 1
                ;;
        esac
        
        sleep $POLL_INTERVAL
        ((count++))
    done
    
    echo ""
    log_error "等待超时"
    return 1
}

# 格式化结果为 Markdown
format_result() {
    local json_file="$1"
    local output_file="$2"
    
    log_info "正在格式化结果..."
    
    python3 << 'PYTHON_SCRIPT' "$json_file" "$output_file"
import sys
import json
from datetime import datetime

json_file = sys.argv[1]
output_file = sys.argv[2]

try:
    with open(json_file, 'r') as f:
        data = json.load(f)
except:
    print(f"无法解析 JSON 文件: {json_file}")
    sys.exit(1)

lines = []

# 元信息
audio_info = data.get('audio_info', {})
duration_ms = audio_info.get('duration', 0)
duration_min = duration_ms / 1000 / 60

lines.append("# 录音转写文稿\n")
lines.append(f"> 音频时长：{duration_min:.1f} 分钟\n")
lines.append(f"> 转写时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
lines.append("")
lines.append("---\n")
lines.append("")

# 识别结果
result = data.get('result', {})
utterances = result.get('utterances', [])

if utterances:
    current_speaker = None
    for utt in utterances:
        text = utt.get('text', '').strip()
        if not text:
            continue
        
        start_ms = utt.get('start_time', 0)
        start_str = f"{start_ms // 60000:02d}:{(start_ms // 1000) % 60:02d}"
        
        additions = utt.get('additions', {})
        speaker = additions.get('speaker_id', '')
        
        if speaker and speaker != current_speaker:
            current_speaker = speaker
            lines.append(f"\n**【说话人 {speaker}】**\n")
        
        lines.append(f"[{start_str}] {text}\n")
else:
    full_text = result.get('text', '')
    if full_text:
        lines.append(full_text)
    else:
        lines.append("（无识别结果）")

with open(output_file, 'w') as f:
    f.write('\n'.join(lines))

print(f"已保存至: {output_file}")
PYTHON_SCRIPT
    
    # 删除临时 JSON 文件
    rm -f "$json_file"
}

# 主函数
main() {
    if [ $# -lt 1 ]; then
        echo "用法: $0 <音频文件路径> [输出文件路径]"
        echo "示例: $0 'Audio Recording 2025-12-26 at 14.04.13.m4a'"
        exit 1
    fi
    
    local input_file="$1"
    local output_file="${2:-${input_file%.*}.md}"
    
    # 转换为绝对路径
    input_file=$(cd "$(dirname "$input_file")" && pwd)/$(basename "$input_file")
    
    if [ ! -f "$input_file" ]; then
        log_error "文件不存在: $input_file"
        exit 1
    fi
    
    # 检查是否已有转写稿
    if [ -f "$output_file" ]; then
        log_warn "转写稿已存在: $output_file"
        read -p "是否覆盖? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "已取消"
            exit 0
        fi
    fi
    
    echo "=================================================="
    echo "录音转写服务 - 火山引擎大模型"
    echo "=================================================="
    log_info "输入文件: $input_file"
    log_info "输出文件: $output_file"
    echo "=================================================="
    
    # 获取公网 IP
    log_info "正在获取公网 IP..."
    local public_ip=$(get_public_ip)
    if [ -z "$public_ip" ]; then
        log_error "无法获取公网 IP"
        exit 1
    fi
    log_info "公网 IP: $public_ip"
    
    # 获取音频格式
    local audio_format=$(get_audio_format "$input_file")
    log_info "音频格式: $audio_format"
    
    # 启动 HTTP 服务器
    local file_dir=$(dirname "$input_file")
    local file_name=$(basename "$input_file")
    
    if ! start_http_server "$file_dir"; then
        exit 1
    fi
    
    # 生成文件 URL
    local audio_url=$(generate_file_url "$file_name" "$public_ip")
    log_info "文件 URL: $audio_url"
    
    # 验证 URL 可访问
    log_info "验证文件可访问..."
    local local_url="http://127.0.0.1:${HTTP_PORT}/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$file_name'))")"
    if ! curl -s --head "$local_url" | head -1 | grep -q "200"; then
        log_error "无法通过 HTTP 访问文件"
        exit 1
    fi
    log_info "本地访问验证通过"
    
    # 提交任务
    local request_id=$(submit_task "$audio_url" "$audio_format")
    if [ -z "$request_id" ]; then
        exit 1
    fi
    
    # 等待结果
    if ! wait_for_result "$request_id" "$output_file"; then
        exit 1
    fi
    
    # 格式化结果
    format_result "$output_file.json" "$output_file"
    
    echo ""
    echo "=================================================="
    log_info "转写完成！"
    log_info "文件已保存至: $output_file"
    echo "=================================================="
}

main "$@"
