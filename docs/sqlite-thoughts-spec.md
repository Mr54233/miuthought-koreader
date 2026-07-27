# 想法存储 SQLite 化 + 原生分页弹框

> 状态:草案,待确认。来源:反向移植 `finlater/weread.koplugin` 的两块独立创新。

## 背景

当前想法弹窗的数据路径:点击锚点 → `Thoughts.find` 读 per-chapter JSON 文件 → 内存 LRU 缓存 → 自绘 HTML 弹窗(`thought_popup.lua` 474 行)渲染。

两个痛点:

1. **大书弹窗取数偏重**:JSON 全章加载 + Lua 侧遍历找 range,再渲染整段 HTML。剑来这种 643 章的书,首次点开一个锚点的 `elapsed_ms` 在真机上 150-550ms,LRU miss 时更明显。
2. **自绘弹窗维护成本高**:474 行手搓 HTML widget,字体嵌入、滚动、分页、关闭按钮全是自己管,bug 面大(此前真机翻车多次)。

`weread.koplugin` 用 per-book SQLite + KOReader 原生 TextViewer 分页解决了这两点,且实现与"下载书"解耦,可直接移植。

## 目标

- 想法存储从 per-chapter JSON 换成 per-book SQLite(`thoughts.db`),点击锚点走单次索引查询
- 弹窗换成 KOReader 原生 TextViewer 分页显示,删除自绘 HTML 弹窗
- **不动**章节映射、后台同步、流式注入、替换模式、防风控、断点续传、`miuxiang-` 锚点格式

## 现状速写(改造前)

```
同步   WebFetch → review_groups → Thoughts.save  → thoughts/{book}/{uid}.json  (per-chapter)
注入   重叠合并 → Thoughts.merge → 重写 {uid}.json
点击   锚点 miuxiang-{book}.{uid}.{range}
       → Thoughts.find(读 JSON 遍历找 range)
       → Thoughts.popup_parts_cached(渲染 HTML,LRU 8)
       → ThoughtPopup.show(自绘 HTML widget)
```

## 改造一:想法存储换 SQLite

### 数据模型(per-book `thoughts.db`)

```sql
CREATE TABLE review_items (
    chapter_uid TEXT  NOT NULL,
    range       TEXT  NOT NULL,
    item_index  INTEGER NOT NULL,
    abstract    TEXT,
    author      TEXT  NOT NULL,
    content     TEXT  NOT NULL,
    PRIMARY KEY (chapter_uid, range, item_index)
) WITHOUT ROWID;
```

- 与 `weread.koplugin` 一致,`chapter_uid` 用 `TEXT`(我们的 uid 本就是字符串)
- WAL + synchronous=NORMAL,依赖 KOReader 内建 `lua-ljsqlite3`
- 文件位置:`store:book_dir(book_id) .. "/thoughts.db"`(与现有 `thoughts/` JSON 目录同级,迁移期并存)

### 写入时机

- **同步时**:`Thoughts.save` 改为写 SQLite(单章一个事务:先 `DELETE WHERE chapter_uid=?` 再批量 INSERT)。保留同名 API 签名,上层 `sync.lua` 无感
- **重叠合并时**:`Thoughts.merge` 改为 `UPDATE review_items SET range=into WHERE chapter_uid=? AND range=from`。语义不变:存活锚点弹窗能看到被合并划线的全部想法

### 读取(点击锚点)

`Thoughts.find` 改为 `SELECT ... WHERE chapter_uid=? AND range=? ORDER BY item_index`,返回与当前同形的 `group`(含 `texts`)。上层 `_show_thought_href` 无感

### 迁移

首次打开有旧 JSON 缓存的书时,一次性导入:读所有 `{uid}.json` → 批量 INSERT → 保留 JSON 作兜底(下下个版本删)。新同步直接写 SQLite,不再写 JSON

## 改造二:原生分页弹框

### 替换自绘弹窗(决策项,见下)

`_show_thought_href` 的取数路径不变(`Thoughts.find` → `group`),弹窗层从 `ThoughtPopup.show{html=...}` 换成 KOReader `TextViewer`:

```
TextViewer:new{
    text = table.concat(格式化后的想法文本, "\n\n———\n\n"),
    title = 引文摘要,
    text_height = 屏幕 60%,
    add_nav_bar = true,   -- 分页
}
```

- 删除 `thought_popup.lua`(474 行)、`Thoughts.paginate / page_html / popup_parts / popup_parts_cached / popup_css`(HTML 渲染那 ~180 行)
- 字体配置沿用 `thoughts.font` 偏好(TextViewer 原生支持 `font_face`)
- 保留 `Thoughts.group_abstract`(摘要)和想法条目格式化(作者 · 点赞 · 内容)

## 不做什么

- **不改锚点格式**(`miuxiang-{hex}`)——已注入的书不失效,`epub_inject.lua` 零改动
- **不改章节映射 / 注入 / 同步编排**——这是数据消费者,生产者不变
- **不双写过渡**——SQLite 唯一真相源,旧 JSON 一次性导入后只读兜底
- **不做"按段落在线拉全量想法"**——那是独立功能(突破 `/review/list` 天花板),与本改造无关

## 兼容性

- **KOReader 版本**:现要求 ≥ v2025.08,该版本含 `lua-ljsqlite3`,无新约束
- **桌面测试**:`lua-ljsqlite3` 在 LuaJIT 桌面环境不可用,需在 `tests/stubs.lua` 加 SQLite mock(内存表 + 同 API 语义)。参照 `archiver_mock` 的惰性索引做法
- **多插件共存**:`thoughts.db` 在我们的数据目录下,与觅阅/微读隔离,沿用 `miuxiang-` 前缀

## 验收标准

1. 点击锚点 → 弹窗显示,首点 `elapsed_ms` 显著下降(目标:剑来 LRU miss 时 < 100ms)
2. 弹窗可分页、字体随偏好、关闭稳定(回归此前真机翻车的"弹窗闪退/无响应"场景)
3. 重叠合并的划线:存活锚点弹窗仍能看到被合并划线的全部想法(已有测试 `test_sync` 的 merge 断言不破)
4. 旧 JSON 缓存的书首次打开,想法不丢(迁移导入验证)
5. 桌面测试全绿(新增 SQLite mock + 弹窗格式化用例)
6. 真机:剑来随机点 3 个不同章节的锚点,均正常弹窗、可翻页

## 待决策项

**D1. 弹窗:替换还是并存?**

推荐**替换**。当前自绘弹窗 474 行、维护重、真机翻车多次;原生 TextViewer 分页更稳。代价:失去"原文+想法同屏混排"的自绘能力(但当前实现这个能力用得也少,主要是想法列表)。

若你想保留自绘弹窗的某些视觉细节(比如当前的内嵌字体),请指明,我改为"并存/可选"方案。

**D2. 迁移:旧 JSON 保留多久?**

推荐**本次保留作只读兜底,下个版本删**。降低本次回归风险。若你接受"一次性导入后立即删 JSON",代码更干净但迁移失败的容错为零。

## 工作量估算

| 模块 | 净增/改动 |
|---|---|
| `thought_db.lua`(新,移植) | +200 行 |
| `thoughts.lua` save/find/merge 改 SQLite | ~150 行改动 |
| `_show_thought_href` + 删 `thought_popup.lua` | -474 +80 行 |
| 迁移逻辑 | +60 行 |
| 桌面 SQLite mock + 测试 | +150 行 |
| **合计** | **净减 ~150 行**,新增 ~490 行 |

预计 2-3 个提交完成,每步可独立验证。
