# 5.9.0 Verification

- 正式版代码基线为 `5.9.0-beta.19`；除版本/通道身份与发布文档外，不改 beta.19 运行逻辑。
- `miuread.koplugin/_meta.lua` 与 `miuread.koplugin/miuread/config.lua`必须同时为 `5.9.0`。
- 默认 OTA 必须为 `stable` / `正式通道` / `stable-channel/update.json`；用户仍可在设置中选择 beta 通道。
- Schema 必须保持 136。
- beta.19 的多锚点映射、fresh source recovery、coordinate-conflict fail-closed、quiet text-anchor landing、progress epoch、ReadReport fresh GET 等保护必须保持。
- Release ZIP 必须只有一个 `miuread.koplugin/` 根目录；不得包含 `.md`、`.epub`、`.log`、`.DS_Store`、`miuread.lua` 或 `settings.reader.lua`。
- 正式 `update.json` 的版本、渠道、包大小与 SHA-256 必须与 `miuread-v5.9.0-full.zip` 一致。
