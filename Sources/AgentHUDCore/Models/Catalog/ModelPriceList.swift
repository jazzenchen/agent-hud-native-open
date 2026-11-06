import Foundation

extension ModelCatalog {
    static let models = BuiltinModelCatalog.shared.models

    /// The provider ids OpenCode, Pi and Kimi give a vendor's own API or plan, and that vendor. Any other provider — a
    /// gateway such as OpenCode Zen, OpenCode Go or OpenRouter, a cloud such as Azure, Bedrock or Vertex, or a proxy —
    /// sells a model at prices of its own, which the catalog does not list.
    static let vendorServices: [String: String] = {
        let services: [String: [String]] = [
            "Anthropic": ["anthropic"],
            "OpenAI": ["openai", "openai-codex"],
            "DeepSeek": ["deepseek"],
            "Google": ["google"],
            "xAI": ["xai"],
            "GLM": ["zai", "zai-coding-plan", "zai-coding-cn", "zhipuai", "zhipuai-coding-plan"],
            "Moonshot": ["moonshotai", "moonshotai-cn", "kimi-code", "kimi-coding", "kimi-for-coding", "kimi-code-plan-cn",
                         "kimi-code-plan-global"],
            "Qwen": ["alibaba", "alibaba-cn", "alibaba-coding-plan", "alibaba-coding-plan-cn", "alibaba-token-plan",
                     "alibaba-token-plan-cn", "qwen-token-plan", "qwen-token-plan-cn", "qwen-token-plan-individual"],
            "MiniMax": ["minimax", "minimax-cn", "minimax-coding-plan", "minimax-cn-coding-plan"],
            "MiMo": ["xiaomi", "xiaomi-token-plan-ams", "xiaomi-token-plan-cn", "xiaomi-token-plan-sgp"],
        ]
        return Dictionary(uniqueKeysWithValues: services.flatMap { vendor, ids in ids.map { ($0, vendor) } })
    }()

}
