# 5.9.0 Verification

## 正式版完成标准

- `config.lua` 与 `_meta.lua` 版本必须均为 `5.9.0`，包身份必须为 `stable / 正式通道`，正式 OTA 必须指向 `stable-channel/update.json`。
- Schema 保持 `136`，不因正式化再次增加迁移。
- beta.12 exact-source refresh 与 writer completion 修复必须保留。
- beta.11 统一手动 progress recovery 与 wake online-ready gate 必须保留。
- beta.10 translation 顶层不得依赖 KOReader `miuread.util` 运行时；数字 bookId 翻译能力必须保留。
- progress submit/verify、`pending_send / submitted_unverified`、remote/local resolver、clock-skew、rollback 与 progress fence 的安全语义不得回退。
- 正式 Release workflow 必须先完成 Lua/回归测试，再创建 workflow_dispatch 对应的正式 Tag。

## 自动验证

- `lua5.1 tools/test_position_resolution.lua`
- `lua5.1 tools/test_position_state_hotfix.lua`
- `lua5.1 tools/test_open_sync_contract.lua`
- `lua5.1 tools/test_beta6_sync_contract.lua`
- `lua5.1 tools/test_beta7_sync_contract.lua`
- `lua5.1 tools/test_beta8_home_translation_contract.lua`
- `lua5.1 tools/test_590_stable_contract.lua`
- `lua5.1 tools/test_cloud_mirror_contract.lua`
- `lua5.1 tools/test_long_book_anchor.lua`
- `lua5.1 tools/test_terminal_progress_guard.lua`
- `lua5.1 tools/test_finished_resolution.lua`
- `lua5.1 tools/test_store_repair.lua`
- `lua5.1 tools/test_cloud_freshness_contract.lua`
- `lua5.1 tools/test_beta10_translation_dependency_contract.lua`
- `luajit tools/test_translation.lua`
- `luajit tools/test_translation_generation.lua`
- `luajit tools/test_translation_fetch.lua`
- `luajit tools/test_internal_links.lua`
- `python3 tools/test_extension_center_ux.py`
- `python3 tools/verify_590_stable.py`

正式安装 ZIP 必须只有一个 `miuread.koplugin/` 根目录，插件版本为 `5.9.0`，更新通道为 stable，Schema 为 136。
