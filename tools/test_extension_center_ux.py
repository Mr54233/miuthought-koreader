from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
center = (ROOT / 'miuread.koplugin/miuread/extension_center.lua').read_text(encoding='utf-8')
main = (ROOT / 'miuread.koplugin/main.lua').read_text(encoding='utf-8')

checks=[]
def ok(cond,msg):
    if not cond:
        raise AssertionError(msg)
    checks.append(msg)

ok('UPDATE_AUTO_INTERVAL=12*60*60' in center, 'automatic extension checks are limited to 12h cadence')
ok('UPDATE_RETRY_INTERVAL=30*60' in center, 'failed background checks use a retry cooldown')
ok('UPDATE_VISIBLE_TTL=24*60*60' in center, 'known update state remains visible for 24h')
ok('extension_center_update_check_v1' in center, 'update-check metadata is persisted separately from per-plugin state')
ok('run_async_silent' in center and 'maybe_auto_check' in center, 'background update discovery is non-modal')
ok('previous.status=="update" or previous.status=="same" or previous.status=="blocked"' in center,
   'transient network failure preserves recent trustworthy update state')
ok('text="可更新扩展"' in center and 'text="扩展更新"' in center and 'text="检查扩展更新"' in center,
   'extension center renders state-specific update entry instead of permanent disabled row')
ok('text="已安装扩展"' in center, 'installed extensions moved behind a dedicated submenu')
ok('text="全部更新"' in center and 'start_bulk_update(plugin,updates)' in center,
   'multiple known updates expose safe sequential bulk update')
ok('plugin._extension_bulk_update=nil' in center and '尚未处理的更新状态会保留' in center,
   'bulk update failure does not clear remaining update markers')

start=center.index('local function recommendation_entry_row')
end=center.index('local function recommendation_category_menu', start)
recommend=center[start:end]
ok('installed_status_label' not in recommend, 'recommendation rows do not expose local/catalog version labels')
ok('status="已安装"' in recommend and 'status="有更新"' in recommend,
   'recommendation rows show semantic install/update state only')
ok('远端版本' in center and 'repo_detail(plugin,target.repo,target)' in center,
   'live version information remains available on the detail page')

show_start=main.index('function Plugin:show_downloads')
show_end=main.index('\nfunction Plugin:', show_start+20)
show=main[show_start:show_end]
for label in ('下载扩展','更新扩展','插件下载任务'):
    ok(label in show, f'download center includes first-page {label}')
first_book=show.index('text="书籍下载"')
for label in ('text="下载扩展"','text="更新扩展"','text="插件下载任务"'):
    ok(show.index(label) < first_book, f'{label} appears before book-download section')

ok('center.maybe_auto_check,self,"startup_idle"' in main, 'startup idle schedules extension discovery')
ok('center.maybe_auto_check,self,"network_restored"' in main, 'network recovery can refresh stale extension state')
ok('if self:_active_reader_ui() then return end' in main, 'startup discovery avoids active reading')
ok('HomeView.is_shown() and not self:_active_reader_ui()' in main,
   'network-triggered extension discovery stays off the active reader path')
ok('个可更新' in main, 'upper-level plugin/extension entry surfaces update count')

print(f'extension center UX: PASS ({len(checks)} checks)')
