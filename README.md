# 觅想 MiuThought:KOReader 微信读书想法同步插件

觅想(MiuThought)是一款非官方 KOReader 插件,只做一件事:把微信读书(WeRead)账号里的**划线与想法**下载下来,注入到你本地已有的 EPUB 中,生成一份「觅想版」副本。

本项目 fork 自 [miumiupy98-art/miuread-koreader](https://github.com/miumiupy98-art/miuread-koreader)(觅阅 MiuRead),现仓库为 [Mr54233/miuthought-koreader](https://github.com/Mr54233/miuthought-koreader)。原项目的书架浏览、书籍搜索、书籍下载、阅读时长/进度同步等功能已在瘦身重构中全部移除。

## 它做什么、不做什么

做:

- 从微信读书拉取指定书籍的划线与想法
- 与本地 EPUB 正文做引文对齐,在对应位置注入锚点与虚线标记
- 重打包生成副本 `原书名.觅想.epub`;阅读副本时,点按标记文字即可弹窗查看该处想法

不做:

- **不下载书籍**——书必须是你本地已有的 EPUB
- **不修改原书**——原书全程只读,注入结果写入新副本(先写临时文件,成功后才改名落盘)
- **不上传任何数据**——不同步阅读时长、阅读进度,对微信读书只读不写

副本内嵌 `miuthought.json` 标记文件,用于识别觅想版:对副本再次执行注入会被拒绝,请始终对原书操作。

## 环境要求

- **KOReader ≥ v2025.08**(硬性要求,不做旧版 fallback)。
  EPUB 的解包与重打包完全依赖该版本起内建的 `ffi/archiver`(libarchive 的 FFI 封装),更早版本会提示缺少 ffi/archiver 而无法使用。技术依据与决策记录见 [docs/task3-zip-feasibility.md](docs/task3-zip-feasibility.md)。
- 主要在 Kindle 上的 KOReader 开发测试;其他 KOReader 平台(Kobo/Android 等)依赖均为 KOReader 内建,理论可用但未完整验证。

## 安装

1. 从 GitHub Releases 下载安装包,解压到 KOReader 插件目录:

   ```text
   koreader/plugins/miuthought.koplugin
   ```

   目录名必须保持为 `miuthought.koplugin`。

2. 重启 KOReader,在主菜单「工具」中找到「觅想 · 微信读书想法同步」。

3. 之后可通过插件菜单「更新与关于 → 检查更新」在线升级(下载后校验大小与 SHA-256)。

## 当前状态

版本 0.1.0,开发中。

已完成:

- 微信读书登录(扫码 / 手动填入凭据)
- EPUB 解析与注入引擎:`epub_reader`(container/OPF/spine 解析)+ `epub_inject`(注入想法锚点并重打包为觅想版副本),带桌面测试
- 想法弹窗:阅读时点按注入的标记,弹窗展示该处划线与想法
- 插件在线更新

开发中:

- 阅读界面内「绑定微信读书 / 同步划线与想法」的端到端编排(当前为占位入口)

## 代码结构

```text
miuthought.koplugin/
├── main.lua                  # 插件入口:菜单、想法弹窗的点按拦截
└── miuthought/
    ├── api.lua / http.lua / auth.lua / cookies.lua   # 微信读书 API 与登录
    ├── annotations.lua       # 注入引擎:分词、引文定位、锚点注入
    ├── annotation_style.lua  # 划线虚线样式
    ├── epub_reader.lua       # ffi/archiver 之上的 EPUB 元数据解析
    ├── epub_inject.lua       # 注入编排:本地 EPUB + 想法数据 → 觅想版副本
    ├── thoughts.lua / thought_popup.lua               # 想法数据与弹窗
    ├── store.lua / config.lua                         # 本地存储与配置
    ├── updater.lua           # 插件在线更新
    └── async.lua / digests.lua / json.lua / protocol.lua / text.lua / util.lua
```

桌面测试(无需 KOReader 环境,使用 KOReader stub 与内存 Archiver mock):

```bash
luajit tests/run.lua
```

## 免责声明

本项目是非官方第三方工具,与微信读书、腾讯及 KOReader 官方无隶属关系。
请仅将本项目用于个人学习和阅读。使用者应自行承担账号、数据和设备相关风险。

## 开源与署名

- 本项目 fork 自 [miumiupy98-art/miuread-koreader](https://github.com/miumiupy98-art/miuread-koreader),感谢原作者的工作。
- 本项目的许可证、原项目署名及第三方代码说明正在整理中。
