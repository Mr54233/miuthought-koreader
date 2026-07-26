local Sync = require("miuthought.sync")

local CH1_TEXT = "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
local CH2_TEXT = "<html><body><p>滟滟随波千万里,何处春江无月明。</p></body></html>"

local function make_deps(overrides)
    local calls = {saved = {}, injected = nil, progress = {}}
    local deps = {
        doc_path = "/books/书.epub",
        book_id = "b001",
        api = {
            chapters = function()
                return {data = {
                    {chapterUid = 1, title = "第一章", chapterIdx = 1},
                    {chapterUid = 2, title = "第二章", chapterIdx = 2},
                }}
            end,
        },
        annotations = {
            fetch_chapter = function(_, _, uid)
                if tostring(uid) == "1" then
                    return {
                        underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {["0-7"] = {{content = "好句", author = "甲"}}},
                        review_groups = {{range = "0-7", texts = {{content = "好句", author = "甲"}}}},
                        underline_count = 1, thought_count = 1, thought_entry_count = 1, errors = {},
                    }
                end
                return {underlines = {}, review_map = {}, review_groups = {},
                    underline_count = 0, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
        load_meta = function()
            return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}}
        end,
        read_text = function(_, href)
            return href == "OEBPS/c1.xhtml" and CH1_TEXT or CH2_TEXT
        end,
        save_thoughts = function(book_id, uid, groups)
            calls.saved[#calls.saved + 1] = {book_id = book_id, uid = tostring(uid), groups = groups}
            return #groups
        end,
        inject = function(src, book_id, mapped)
            calls.injected = {src = src, book_id = book_id, mapped = mapped}
            return {dest = "/books/书.觅想.epub", injected = #mapped, marks = #mapped,
                unmatched = {}, quote_aligned = #mapped, dropped = 0}
        end,
        progress = function(phase, i, n, text)
            calls.progress[#calls.progress + 1] = {phase = phase, i = i, n = n, text = text}
            return true
        end,
    }
    for k, v in pairs(overrides or {}) do deps[k] = v end
    return deps, calls
end

T.case("同步全流程", function()
    local deps, calls = make_deps()
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(report.chapters_total, 2, "章节总数")
    T.eq(report.chapters_with_data, 1, "有划线章节数")
    T.eq(report.injected, 1, "注入章节数")
    T.eq(report.thoughts_saved, 1, "想法缓存章节数")
    T.eq(report.dest, "/books/书.觅想.epub", "dest 透传")
    T.eq(report.fetch_errors, 0, "无拉取错误")
    T.eq(#calls.saved, 1, "save_thoughts 调用一次")
    T.eq(calls.saved[1].uid, "1", "缓存第一章")
    T.eq(#calls.injected.mapped, 1, "注入一章")
    T.eq(calls.injected.mapped[1].href, "OEBPS/c1.xhtml", "映射到 c1")
    T.eq(calls.injected.mapped[1].chapter_uid, "1", "chapter_uid 传递")
    T.ok(#calls.progress >= 3, "进度回调发生")
end)

T.case("进度回调返回 false 即取消", function()
    local deps, calls = make_deps({
        progress = function(phase) return phase ~= "fetch" end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("取消", 1, true), "取消: " .. tostring(err))
    T.eq(calls.injected, nil, "取消后不得注入")
end)

T.case("全书无划线", function()
    local deps = make_deps({
        annotations = {
            fetch_chapter = function()
                return {underlines = {}, review_map = {}, review_groups = {},
                    underline_count = 0, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("没有划线", 1, true), "无划线报错: " .. tostring(err))
end)

T.case("全部章节拉取失败按网络错误报", function()
    local deps = make_deps({
        annotations = {
            fetch_chapter = function() error("network request failed") end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("拉取失败", 1, true), "全失败报错: " .. tostring(err))
end)

T.case("章节列表接口失败", function()
    local deps = make_deps({
        api = {chapters = function() error("boom") end},
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("章节列表失败", 1, true), "报错: " .. tostring(err))
end)

T.case("引文全不匹配本地书", function()
    local deps = make_deps({
        read_text = function() return "<html><body>完全无关的另一本书内容</body></html>" end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("匹配", 1, true), "映射失败报错: " .. tostring(err))
end)

T.case("连续硬失败触发断网熔断", function()
    local rows = {}
    for i = 1, 10 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local fetch_count = 0
    local deps, calls = make_deps({
        api = {chapters = function() return {data = rows} end},
        annotations = {
            fetch_chapter = function() fetch_count = fetch_count + 1; error("network request failed") end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("连续", 1, true), "熔断报错: " .. tostring(err))
    T.ok(tostring(err):find("network request failed", 1, true), "熔断消息必须带真实错误: " .. tostring(err))
    T.eq(fetch_count, 3, "连续 3 章失败即中止,不磨完全书")
    T.eq(calls.injected, nil, "熔断后不注入")
end)

T.case("断点缓存命中不复位熔断计数", function()
    local rows = {}
    for i = 1, 7 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local fetch_calls = 0
    local deps = make_deps({
        api = {chapters = function() return {data = rows} end},
        annotations = {
            fetch_chapter = function(_, _, uid)
                fetch_calls = fetch_calls + 1
                local n = tonumber(uid)
                if n % 2 == 0 then
                    -- 偶数章:断点缓存命中(resumed),不发网络
                    return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {}, review_groups = {}, resumed = true,
                        underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {}}
                end
                error("network request failed")
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("连续", 1, true),
        "缓存命中穿插的连续网络失败仍应熔断: " .. tostring(err))
    T.eq(fetch_calls, 5, "第 5 章(第 3 次真实失败)后中止")
end)

T.case("末尾连续失败且成功章节无划线时报拉取失败而非无划线", function()
    local rows = {}
    for i = 1, 4 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local deps = make_deps({
        api = {chapters = function() return {data = rows} end},
        annotations = {
            fetch_chapter = function(_, _, uid)
                if tostring(uid) == "1" then
                    return {underlines = {}, review_map = {}, review_groups = {},
                        underline_count = 0, thought_count = 0, thought_entry_count = 0, errors = {}}
                end
                error("network request failed")
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil, "应失败")
    T.ok(tostring(err):find("拉取失败", 1, true), "归因网络: " .. tostring(err))
    T.ok(not tostring(err):find("这本书在微信读书里没有划线", 1, true), "不得误报为书无划线")
end)

T.case("想法缓存写失败计入 save_failures 不计入 thoughts_saved", function()
    local deps, _ = make_deps({
        save_thoughts = function() return nil, "磁盘满" end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(report.thoughts_saved, 0, "写失败不算保存成功")
    T.eq(report.save_failures, 1, "写失败计数")
end)

T.case("单章拉取失败不中断,计入 fetch_errors", function()
    local deps, calls = make_deps({
        annotations = {
            fetch_chapter = function(_, _, uid)
                if tostring(uid) == "2" then error("timeout") end
                return {
                    underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                    review_map = {}, review_groups = {},
                    underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {},
                }
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(report.fetch_errors, 1, "失败章节计数")
    T.eq(report.injected, 1, "成功章节照常注入")
end)
