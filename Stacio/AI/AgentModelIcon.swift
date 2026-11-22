import AppKit

@MainActor
extension AgentModelSelection {
 private static var modelIcons: [String: NSImage] = [:]

 func pickerIcon() -> NSImage? {
 let fallback = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
 let modelName = modelID.split(separator: "/").last.map(String.init) ?? modelID
 guard let brand = Self.iconBrand(in: modelName)
 ?? Self.iconBrand(in: modelDisplayName)
 ?? Self.iconBrand(in: modelID)
 ?? Self.iconBrand(in: providerName) else { return fallback }
 if let cached = Self.modelIcons[brand] { return cached }
 let ext = ["zcode", "workbuddy", "officeace", "deepseek-harness"].contains(brand) ? "png" : "svg"
 let url = Bundle.main.url(forResource: brand, withExtension: ext, subdirectory: "AIModelIcons")
 ?? StacioPackageResources.moduleBundle?.url(forResource: brand, withExtension: ext, subdirectory: "AIModelIcons")
 guard let url, let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else { return fallback }
 let image = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { bounds in
 let scale = min(bounds.width / source.size.width, bounds.height / source.size.height)
 let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
 source.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                        width: size.width, height: size.height))
 return true
 }
 image.isTemplate = ["openai", "grok", "glm", "opencode", "hermesagent", "happyhorse", "bytedance", "agnesai", "stepfun"].contains(brand)
 Self.modelIcons[brand] = image
 return image
 }

 private static func iconBrand(in value: String) -> String? {
 let name = value.lowercased()
 if name.contains("deepseek") && name.contains("harness") { return "deepseek-harness" }
 if name.contains("office ace") { return "officeace" }
 let parts = Set(name.split { !$0.isLetter && !$0.isNumber })
 if parts.contains("codex") { return "codex" }
 if parts.contains("claude") || parts.contains("anthropic") { return "claude" }
 if parts.contains("deepseek") || name.contains("深度求索") { return "deepseek" }
 if parts.contains("gemini") { return "gemini" }
 if parts.contains(where: { $0.hasPrefix("qwen") }) || name.contains("通义千问") { return "qwen" }
 if parts.contains("grok") || parts.contains("xai") { return "grok" }
 if parts.contains("llama") || parts.contains("meta") { return "llama" }
 if parts.contains("glm") || parts.contains("zhipu") || name.contains("智谱") || name == "z.ai" { return "glm" }
 if name.contains("doubao") || name.contains("豆包") { return "doubao" }
 if name.contains("hunyuan") || name.contains("混元") { return "hunyuan" }
 if parts.contains("openai") || parts.contains("chatgpt") || parts.contains("gpt")
 || parts.contains(where: { ["o1", "o3", "o4"].contains($0) }) { return "openai" }
 if parts.contains("kimi") || parts.contains("moonshot") || name.contains("月之暗面") { return "kimi" }
 if parts.contains("gemma") { return "gemma" }
 if parts.contains("codebuddy") { return "codebuddy" }
 if parts.contains("trae") { return "trae" }
 if parts.contains("infinigence") { return "infinigence" }
 if parts.contains("huggingface") { return "huggingface" }
 if parts.contains("modelscope") { return "modelscope" }
 if parts.contains("skywork") || name.contains("天工") { return "skywork" }
 if parts.contains("ai360") { return "ai360" }
 if parts.contains("yuanbao") || name.contains("元宝") { return "yuanbao" }
 if parts.contains("qingyan") || name.contains("清言") { return "qingyan" }
 if parts.contains("openclaw") { return "openclaw" }
 if parts.contains("happyhorse") { return "happyhorse" }
 if parts.contains("opencode") { return "opencode" }
 if parts.contains("hermesagent") || parts.contains("hermes") { return "hermesagent" }
 if parts.contains("agnesai") { return "agnesai" }
 if parts.contains("bytedance") || name.contains("字节跳动") { return "bytedance" }
 if parts.contains("ernie") || name.contains("文心") { return "ernie" }
 if parts.contains("spark") || name.contains("讯飞星火") { return "spark" }
 if parts.contains("stepfun") || parts.contains("step") || name.contains("阶跃星辰") { return "stepfun" }
 if parts.contains("zcode") { return "zcode" }
 if parts.contains("workbuddy") { return "workbuddy" }
 if parts.contains("officeace") { return "officeace" }
 return nil
 }
}
