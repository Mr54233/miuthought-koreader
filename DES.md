# 5.9.0

5.9.0 是从 `5.9.0-beta.19` 直接收口的正式版本。正式化过程不修改 beta.19 已验证的同步算法，只统一正式版本号、默认 OTA 通道与发布文档，因此运行行为与 beta.19 保持一致。

本版的核心是多设备阅读进度安全。开书时以可信 verified anchor、同步因果、真实阅读事件和云端更新时间判断本机/云端哪一侧更新；远端尚未确认、远端更新、冲突或远端精确坐标未解析时，progress write fence 会阻止旧本机位置自动写回。失败恢复继续采用 verify-first，并保留 progress epoch、clean-state migration、ghost-write guard，以及“以云端为准 / 以本机为准”的显式处理。

精确位置仍以微信原生 `chapter_uid + co` 为最终验收。本地→云端使用围绕同一 XPointer 的 `forward/backward 24、16、12` 多级 immutable anchors，并可在旧 source cache 失败后获取 fresh Web Reader context/source 再映射。只有唯一正文锚点能够导出一致的 native `wr_data_co` 才允许上传；多个锚点导出不同坐标、正文不唯一或 source 无法可靠恢复时都继续 fail closed。

云端→本地保留 `chapter rescue -> text anchor -> exact verify` 主链。当 text anchor 已唯一命中正确章节正文时，导航落点本身被视为可靠，不再因为反向 local→co 暂时无法完成而显示误导性的“精确位置未确认”，也不再让 percent correction 覆盖已经成功的正文落点。内部 `remote_exact_unresolved` write fence 仍然存在，因此可靠导航与允许回写云端仍是两个独立条件。

5.9.0 同时纳入外文翻译三态、安全译文 EPUB 替换、主页刷新/同步入口统一、同步失败闭环，以及 5.8 后期已经整合的扩展中心、下载与设备体验改进。ReadReport 保持 v30，阅读时间继续 fresh-GET-before-POST；Schema 保持 136。
