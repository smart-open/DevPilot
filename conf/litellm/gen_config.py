#!/usr/bin/env python3
# ============================================================
# LiteLLM 配置生成器
# 读取 .env 中各平台凭据（AGNES_* / DEEPSEEK_* / GLM_* / ARK_* / BAILIAN_*），
# 为每个「key 有效」的平台注册一个模型，输出 litellm_config.yaml。
#
# 注册后的模型名格式为 <platform>/<model>（如 agnes/agnes-2.5-flash），
# 与 Claude Code 侧 ANTHROPIC_MODEL 完全一致，也与 OpenClaw 的模型命名对齐。
# Claude Code 请求 /v1/messages 时携带该 model，litellm 翻译为 OpenAI
# Chat Completions 转发到对应平台的 api_base。
# ============================================================
import os
import sys
import yaml

# 平台定义：(env 前缀, 默认 api_base, 默认 model)
PLATFORMS = {
    "agnes":    ("AGNES",    "https://api.agnes-ai.cn/v1",                        "agnes-2.5-flash"),
    "deepseek": ("DEEPSEEK", "https://api.deepseek.com/v1",                       "DeepSeek-V4-Flash"),
    "glm":      ("GLM",      "https://open.bigmodel.cn/api/paas/v4",              "GLM-5.2"),
    "ark":      ("ARK",      "https://ark.cn-beijing.volces.com/api/v3",          "doubao-seed-2.1-turbo"),
    "bailian":  ("BAILIAN",  "https://dashscope.aliyuncs.com/compatible-mode/v1", "Qwen3.7-Plus"),
}


def env(*names, default=""):
    for n in names:
        v = os.environ.get(n, "")
        if v:
            return v
    return default


def is_real(v: str) -> bool:
    """判断 API Key 是否为真实值（排除空值 / 占位符 / 模板变量）。"""
    if not v:
        return False
    if v.startswith("your-") or v.startswith("change-me"):
        return False
    if "{{" in v or "}}" in v:
        return False
    return True


def main():
    model_list = []
    for pname, (prefix, def_base, def_model) in PLATFORMS.items():
        key = env(f"{prefix}_API_KEY")
        if not is_real(key):
            continue
        base = env(f"{prefix}_BASE_URL", default=def_base)
        model = env(f"{prefix}_MODEL", default=def_model)
        model_list.append({
            "model_name": f"{pname}/{model}",
            "litellm_params": {
                "model": model,
                "api_base": base,
                "api_key": key,
            },
        })

    master_key = os.environ.get("LITELLM_MASTER_KEY") or "sk-devpilot-litellm"

    config = {
        "general_settings": {
            "master_key": master_key,
            "disable_spend_logs": True,
        },
        "litellm_settings": {
            # 容忍 Claude Code 可能下发的、上游不认识的参数
            "drop_params": True,
            # 重要：v1.82 起 /v1/messages 默认走 /responses，改为 chat/completions
            "use_chat_completions_url_for_anthropic_messages": True,
        },
        "model_list": model_list,
    }

    out = "/app/litellm_config.yaml"
    with open(out, "w", encoding="utf-8") as f:
        yaml.safe_dump(config, f, allow_unicode=True, sort_keys=False)

    if not model_list:
        print("[gen_config] ERROR: 没有任何平台配置了有效的 API Key，litellm 无可用模型。")
        print("[gen_config] 请检查 .env 中的 <PLATFORM>_API_KEY（至少 agnes 须有效）。")
        sys.exit(1)

    print(f"[gen_config] 已生成 {out}，注册模型数={len(model_list)}")
    for m in model_list:
        print("  -", m["model_name"], "->", m["litellm_params"]["api_base"])


if __name__ == "__main__":
    main()
