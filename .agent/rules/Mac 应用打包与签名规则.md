---
trigger: always_on
---

## 四、Mac 应用打包与签名规则

### 核心原则

1. **证书来源**：从 `.env` 文件读取 `DEVELOPER_ID_CERT` 环境变量
2. **证书选择**：始终使用 Developer ID 证书签名（无论开发还是分发）
3. **必做步骤**：签名后必须执行 `xattr -cr` 清除隔离属性

### 关键命令

```bash
# 加载环境变量
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# 签名
codesign --force --deep --sign "$DEVELOPER_ID_CERT" "build/$APP_NAME"

# 清除隔离属性（必须）
xattr -cr "build/$APP_NAME"
```

### 证书配置

证书信息存放在 `.env` 文件中（已加入 .gitignore）：
- **DEVELOPER_ID_CERT**：付费证书（$99/年），用于分发