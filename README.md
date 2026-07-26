# 觅想 MiuThought:KOReader 微信读书想法同步插件

觅想(MiuThought)是一款非官方 KOReader 插件,只做一件事:把微信读书(WeRead)上的**热门划线与公开想法**拉取下来,注入到你本地已有的 EPUB 中——阅读时点按虚线文字,弹窗查看这一段其他读者的想法。

本项目 fork 自 [miumiupy98-art/miuread-koreader](https://github.com/miumiupy98-art/miuread-koreader)(觅阅 MiuRead),现仓库为 [Mr54233/miuthought-koreader](https://github.com/Mr54233/miuthought-koreader)。原项目的书架浏览、书籍搜索、书籍下载、阅读时长/进度同步等功能已全部移除。

## 它做什么、不做什么

做:

- 从微信读书拉取书籍的热门划线与公开想法(web 端接口,Cookie 鉴权,登录态自动续期;**会员书同样可拉**——付费墙锁的是正文,不锁社区数据,而正文来自你本地)
- 与本地 EPUB 正文做引文对齐,在对应位置注入虚线锚点;同步完成后**原地替换**你正在读的书(阅读进度保留),原版自动备份为 `原书名.epub.orig`,菜单可一键还原
- 阅读时点按虚线弹窗查看想法;同一段的重叠划线自动合并,想法归拢到一个锚点

不做:

- **不下载书籍**——书必须是你本地已有的 EPUB
- **不丢原书**——替换前自动备份 `.orig`,「还原原书」随时退回
- **不上传任何数据**——对微信读书只读不写

注入过的书内嵌 `miuthought.json` 标记:对它再次注入会被拒绝,同步永远从 `.orig` 干净源重做,不会叠加污染。

## 核心特性

- **后台同步**:同步跑在独立子进程,进度框可「转入后台」继续看书,菜单随时调回;防锁屏(保持唤醒 + 按住自动休眠),KOReader 重启后自动接管仍在运行的任务
- **断点续传**:每章拉取结果落盘,取消/断网/中断后再次同步自动跳过已拉章节;网络死吊由看门狗兜底(静默 6 分钟终止并保留断点)
- **大书分批(防风控)**:单次同步最多拉 300 个新章节,章间随机停顿;剩余章节用「继续拉取后续章节」手动补,或阅读接近已同步末尾时自动后台补(可关)
- **离线重新注入**:完整同步过一次后,「重新注入」零网络重跑映射+注入(换了本地书版本、还原后想重打时用)
- **章节映射**:引文投票 + 章名兜底,支持"微信一章 = 本地多章"的拆分注入、微信与本地章号体系不一致、精校版文字差异;映射结果缓存,续批秒级
- **多插件共存**:锚点前缀(`miuxiang-`)、设置文件、数据目录均与觅阅/微读隔离,三者可同装互不干扰

## 环境要求

- **KOReader ≥ v2025.08**(硬性要求,不做旧版 fallback)。
  EPUB 的解包与重打包完全依赖该版本起内建的 `ffi/archiver`(libarchive 的 FFI 封装),更早版本会提示缺少 ffi/archiver 而无法使用。技术依据与决策记录见 [docs/task3-zip-feasibility.md](docs/task3-zip-feasibility.md)。
- 主要在 Kindle 上开发测试;其他 KOReader 平台(Kobo/Android 等)依赖均为 KOReader 内建,理论可用但未完整验证。

## 安装与使用

1. 下载后解压到 KOReader 插件目录(目录名必须保持 `miuthought.koplugin`):

   ```text
   koreader/plugins/miuthought.koplugin
   ```

2. 重启 KOReader,主菜单「工具」中找到「觅想 · 微信读书想法同步」。

3. 使用流程:
   - 「账户」里扫码登录微信读书(或手动填入凭据)
   - 打开一本本地 EPUB → 「绑定微信读书」搜索并选中对应书目(也可在文件管理器菜单里直接选书绑定/同步,不必先打开书)
   - 「同步划线与想法」→ 进度框可取消/转后台 → 完成后直接阅读,点虚线看想法

4. 之后可通过「更新与关于 → 检查更新」在线升级(下载后校验大小与 SHA-256)。

## 代码结构

```text
miuthought.koplugin/
├── main.lua                  # 插件入口:菜单、同步运行时、想法弹窗点按拦截
└── miuthought/
    ├── api.lua / http.lua / auth.lua / cookies.lua   # 微信读书 web 接口与登录(自动续期)
    ├── web_fetch.lua         # 数据源:热门划线 + 章节公开想法
    ├── sync.lua              # 同步编排:拉取→缓存→映射→注入→替换(依赖注入可测)
    ├── sync_task.lua         # 后台子进程任务:进度/取消/断点/看门狗/保持唤醒
    ├── sync_progress.lua     # 进度对话框(取消 / 后台)
    ├── chapter_map.lua       # 章节映射:引文投票、拆分章、章名兜底、结果缓存
    ├── annotations.lua       # 注入引擎:分词、引文定位、锚点注入
    ├── annotation_style.lua  # 划线虚线样式
    ├── epub_reader.lua       # ffi/archiver 之上的 EPUB 元数据解析
    ├── epub_inject.lua       # 注入编排:锚点写入 + 重打包
    ├── binding.lua           # 本地书 ↔ 微信书目绑定
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
