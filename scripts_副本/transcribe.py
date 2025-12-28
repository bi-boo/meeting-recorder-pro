#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
火山引擎录音文件识别服务
用于将音频文件转换为文字稿

使用方法：
    python transcribe.py <音频文件路径>

支持的音频格式：mp3, m4a, wav, ogg
"""

import os
import sys
import json
import time
import uuid
import base64
import hashlib
import requests
import re
from pathlib import Path
from datetime import datetime

# 火山引擎 API 配置
VOLCENGINE_APP_ID = "2505335848"
VOLCENGINE_ACCESS_TOKEN = "sHrVzn0mOgUbUF2Dvu-h17H7czytWk6i"

# API 端点
SUBMIT_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"
QUERY_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query"

# 资源 ID（使用豆包录音文件识别模型2.0）
RESOURCE_ID = "volc.seedasr.auc"

# 轮询配置
POLL_INTERVAL = 5  # 轮询间隔（秒）
MAX_POLL_TIME = 3600  # 最大等待时间（秒）

# 热词配置文件路径
HOTWORDS_FILE = Path(__file__).parent / "hotwords.md"


def get_audio_format(file_path: str) -> str:
    """根据文件扩展名获取音频格式"""
    ext = Path(file_path).suffix.lower()
    format_map = {
        '.mp3': 'mp3',
        '.m4a': 'mp3',  # m4a 按 mp3 处理
        '.wav': 'wav',
        '.ogg': 'ogg',
        '.raw': 'raw',
    }
    return format_map.get(ext, 'mp3')


def upload_to_temp_storage(file_path: str) -> str:
    """
    将本地文件上传到腾讯云 CloudBase 云存储并获取公网访问 URL
    """
    import subprocess
    import re
    
    env_id = "thenextq-6g7bemmi5ea4ce29"
    file_path_obj = Path(file_path)
    remote_path = f"transcribe/{file_path_obj.name}"
    
    print(f"正在上传文件到腾讯云 CloudBase...")
    
    try:
        # 上传文件
        upload_cmd = [
            "tcb", "storage", "upload", 
            str(file_path), remote_path,
            "-e", env_id
        ]
        upload_res = subprocess.run(upload_cmd, capture_output=True, text=True)
        if upload_res.returncode != 0:
            print(f"TCB 上传失败 (stderr): {upload_res.stderr}")
            raise Exception(f"TCB 上传失败，返回码: {upload_res.returncode}")
        
        # 获取临时链接
        url_cmd = [
            "tcb", "storage", "url",
            remote_path,
            "-e", env_id
        ]
        url_result = subprocess.run(url_cmd, capture_output=True, text=True)
        if url_result.returncode != 0:
            print(f"TCB 获取链接失败 (stderr): {url_result.stderr}")
            raise Exception(f"TCB 获取链接失败，返回码: {url_result.returncode}")
            
        # 使用正则提取 URL（处理包含空格的情况）
        # TCB 输出格式通常是: ✔ File temporary access address: https://...
        url_match = re.search(r'https?://[^\r\n]+', url_result.stdout)
        if url_match:
            url = url_match.group(0).strip()
            print(f"文件上传成功并获取链接: {url}")
            return url
        else:
            print(f"TCB 输出内容: {url_result.stdout}")
            raise Exception("未从 TCB 输出中提取到下载链接")
            
    except Exception as e:
        print(f"TCB 操作过程中出现错误: {e}")
        raise e


def load_hotwords() -> list:
    """
    从 hotwords.md 加载热词列表
    """
    hotwords = []
    if not HOTWORDS_FILE.exists():
        print(f"提示：未找到热词配置文件 {HOTWORDS_FILE}，将跳过热词加载。")
        return hotwords
    
    try:
        with open(HOTWORDS_FILE, 'r', encoding='utf-8') as f:
            content = f.read()
            # 匹配 "- 词语" 格式
            matches = re.findall(r'^\s*-\s+(.+)$', content, re.MULTILINE)
            hotwords = [{"word": m.strip()} for m in matches if m.strip()]
            
        if hotwords:
            print(f"成功从配置文件加载了 {len(hotwords)} 个热词。")
        return hotwords
    except Exception as e:
        print(f"加载热词文件出错: {e}")
        return []


def submit_transcription_task(audio_url: str, audio_format: str) -> str:
    """
    提交录音识别任务
    
    Args:
        audio_url: 音频文件的 URL
        audio_format: 音频格式（mp3/wav/ogg）
    
    Returns:
        request_id: 任务 ID
    """
    request_id = str(uuid.uuid4())
    
    headers = {
        'Content-Type': 'application/json',
        'X-Api-App-Key': VOLCENGINE_APP_ID,
        'X-Api-Access-Key': VOLCENGINE_ACCESS_TOKEN,
        'X-Api-Resource-Id': RESOURCE_ID,
        'X-Api-Request-Id': request_id,
        'X-Api-Sequence': '-1',
    }
    
    payload = {
        "user": {
            "uid": "weekly-report-transcription"
        },
        "audio": {
            "format": audio_format,
            "url": audio_url
        },
        "request": {
            "model_name": "bigmodel",
            "model_version": "400",           # 使用400模型（ITN优化更好）
            "enable_itn": True,               # 启用文本规范化
            "enable_punc": True,              # 启用标点
            "enable_ddc": True,               # 启用语义顺滑
            "show_utterances": True,          # 输出分句信息
            "enable_speaker_info": True,      # 启用说话人分离
            "show_speech_rate": True,         # 输出语速信息
            "enable_emotion_detection": True, # 启用情绪检测
            "enable_gender_detection": True,  # 启用性别检测
        },
        "corpus": {
            "context": json.dumps({
                "hotwords": load_hotwords()
            })
        }
    }
    
    print(f"正在提交转写任务...")
    print(f"Request ID: {request_id}")
    
    response = requests.post(
        SUBMIT_URL,
        headers=headers,
        json=payload,
        timeout=30
    )
    
    status_code = response.headers.get('X-Api-Status-Code', '')
    message = response.headers.get('X-Api-Message', '')
    
    if status_code == '20000000':
        print(f"任务提交成功！")
        return request_id
    else:
        raise Exception(f"任务提交失败: {message} (code: {status_code})")


def query_transcription_result(request_id: str) -> dict:
    """
    查询转写结果
    
    Args:
        request_id: 任务 ID
    
    Returns:
        result: 转写结果
    """
    headers = {
        'Content-Type': 'application/json',
        'X-Api-App-Key': VOLCENGINE_APP_ID,
        'X-Api-Access-Key': VOLCENGINE_ACCESS_TOKEN,
        'X-Api-Resource-Id': RESOURCE_ID,
        'X-Api-Request-Id': request_id,
    }
    
    response = requests.post(
        QUERY_URL,
        headers=headers,
        json={},
        timeout=30
    )
    
    status_code = response.headers.get('X-Api-Status-Code', '')
    message = response.headers.get('X-Api-Message', '')
    
    if status_code == '20000000':
        # 成功
        return {
            'status': 'success',
            'data': response.json()
        }
    elif status_code in ['20000001', '20000002']:
        # 处理中 或 队列中
        return {
            'status': 'processing',
            'message': message
        }
    elif status_code == '20000003':
        # 静音音频
        return {
            'status': 'silent',
            'message': '音频为静音，没有可识别的内容'
        }
    else:
        return {
            'status': 'error',
            'message': f"{message} (code: {status_code})"
        }


def wait_for_result(request_id: str) -> dict:
    """
    等待转写完成并返回结果
    
    Args:
        request_id: 任务 ID
    
    Returns:
        result: 转写结果
    """
    start_time = time.time()
    
    while True:
        elapsed = time.time() - start_time
        
        if elapsed > MAX_POLL_TIME:
            raise Exception(f"等待超时（{MAX_POLL_TIME}秒），请稍后重试")
        
        result = query_transcription_result(request_id)
        
        if result['status'] == 'success':
            return result['data']
        elif result['status'] == 'processing':
            print(f"处理中... ({int(elapsed)}秒)")
            time.sleep(POLL_INTERVAL)
        elif result['status'] == 'silent':
            raise Exception(result['message'])
        else:
            raise Exception(f"转写失败: {result['message']}")


def format_transcript(result: dict) -> str:
    """
    格式化转写结果为 Markdown 文本
    
    Args:
        result: 火山引擎返回的结果
    
    Returns:
        markdown: 格式化后的 Markdown 文本
    """
    lines = []
    
    # 添加元信息
    audio_info = result.get('audio_info', {})
    duration_ms = audio_info.get('duration', 0)
    duration_min = duration_ms / 1000 / 60
    
    lines.append(f"# 录音转写文稿\n")
    lines.append(f"> 音频时长：{duration_min:.1f} 分钟\n")
    lines.append(f"> 转写时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    lines.append("")
    lines.append("---\n")
    lines.append("")
    
    # 获取识别结果
    text_result = result.get('result', {})
    
    # 如果有分句信息，按分句输出
    utterances = text_result.get('utterances', [])
    
    if utterances:
        current_speaker = None
        
        for utt in utterances:
            text = utt.get('text', '').strip()
            if not text:
                continue
            
            # 时间戳
            start_ms = utt.get('start_time', 0)
            end_ms = utt.get('end_time', 0)
            start_str = f"{start_ms // 60000:02d}:{(start_ms // 1000) % 60:02d}"
            
            # 说话人信息和附加信息
            additions = utt.get('additions', {})
            speaker = additions.get('speaker_id', '')
            gender = additions.get('gender', '')
            emotion = additions.get('emotion', '')
            speech_rate = additions.get('speech_rate', '')
            
            # 如果说话人变了，添加分隔
            if speaker and speaker != current_speaker:
                current_speaker = speaker
                gender_text = f" ({gender})" if gender else ""
                lines.append(f"\n**【说话人 {speaker}{gender_text}】**\n")
            
            # 构建附加信息标签
            tags = []
            if emotion:
                emotion_map = {
                    'angry': '😠生气',
                    'happy': '😊开心', 
                    'neutral': '😐中性',
                    'sad': '😢悲伤',
                    'surprise': '😲惊讶'
                }
                tags.append(emotion_map.get(emotion, emotion))
            if speech_rate:
                tags.append(f"语速{speech_rate:.1f}")
            
            tag_text = f" [{', '.join(tags)}]" if tags else ""
            
            # 添加带时间戳和标签的文本
            lines.append(f"[{start_str}]{tag_text} {text}\n")
    else:
        # 没有分句信息，直接输出完整文本
        full_text = text_result.get('text', '')
        lines.append(full_text)
    
    return '\n'.join(lines)


def transcribe_audio(file_path: str, output_path: str = None) -> str:
    """
    主函数：将音频文件转写为文字稿
    
    Args:
        file_path: 音频文件路径
        output_path: 输出文件路径（可选，默认为同名 .md 文件）
    
    Returns:
        output_path: 输出文件路径
    """
    file_path = Path(file_path)
    
    if not file_path.exists():
        raise FileNotFoundError(f"文件不存在: {file_path}")
    
    # 确定输出路径
    if output_path is None:
        output_path = file_path.with_suffix('.md')
    else:
        output_path = Path(output_path)
    
    print(f"\n{'='*50}")
    print(f"录音转写服务 - 火山引擎大模型")
    print(f"{'='*50}")
    print(f"输入文件: {file_path}")
    print(f"输出文件: {output_path}")
    print(f"{'='*50}\n")
    
    # 获取音频格式
    audio_format = get_audio_format(str(file_path))
    print(f"音频格式: {audio_format}")
    
    # 上传文件获取 URL
    audio_url = upload_to_temp_storage(str(file_path))
    
    # 提交转写任务
    request_id = submit_transcription_task(audio_url, audio_format)
    
    # 等待结果
    print(f"\n等待转写完成...")
    result = wait_for_result(request_id)
    
    # 格式化结果
    print(f"\n正在格式化结果...")
    transcript = format_transcript(result)
    
    # 保存结果
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(transcript)
    
    print(f"\n{'='*50}")
    print(f"转写完成！")
    print(f"文件已保存至: {output_path}")
    print(f"{'='*50}\n")
    
    return str(output_path)


def main():
    """命令行入口"""
    if len(sys.argv) < 2:
        print("用法: python transcribe.py <音频文件路径> [输出文件路径]")
        print("示例: python transcribe.py 【录音】周会 2025.12.23.m4a")
        sys.exit(1)
    
    file_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else None
    
    try:
        transcribe_audio(file_path, output_path)
    except Exception as e:
        print(f"\n错误: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
