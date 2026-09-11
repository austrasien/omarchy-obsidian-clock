import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The clock's calendar popup: a month grid with ISO week numbers, plus
// the Obsidian daily journal for the selected day.
Panel {
  id: root
  moduleName: "austraz.clock"
  ipcTarget: "austraz.clock"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Today. SystemClock keeps this honest across midnight so the
  //      highlight rolls over without the panel being reopened.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  // The month on screen. Stepping moves this and nothing else: the grid is
  // a read-out, not a picker, so there is no per-day cursor to keep in sync.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()
  property string selectedKey: todayKey
  property string hoveredKey: ""

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string vaultPath: String(setting("vaultPath", "") || "").trim()
  property string hostArch: ""
  property string resolvedJournalBin: ""
  readonly property string journalBin: root.resolvedJournalBin

  property string journalNotes: ""
  property string journalDraft: ""
  property bool journalDirty: false
  property string journalSynced: ""
  property string journalTab: ""
  property var tabHeadings: []
  property var sectionDrafts: ({})
  property var sectionSynced: ({})
  property bool applyingJournal: false
  property string editorLoadedKey: ""
  property bool tasksDoneExpanded: false
  property bool sectionDoneExpanded: false
  property bool pendingTodoFocus: false
  property int todoFocusTries: 0
  readonly property var journalTabs: {
    var heads = root.tabHeadings || []
    var out = []
    for (var i = 0; i < heads.length && out.length < 6; i++) {
      var heading = String(heads[i] || "").trim()
      if (heading === "" || root.isTasksHeading(heading)) continue
      var glyph = root.tabGlyph(heading)
      out.push({
        key: heading,
        label: glyph !== "" ? glyph : heading,
        tooltip: "Edit " + heading,
        iconOnly: glyph !== ""
      })
    }
    return out
  }
  readonly property string tasksHeading: {
    var heads = root.tabHeadings || []
    for (var i = 0; i < heads.length; i++) {
      var heading = String(heads[i] || "").trim()
      if (root.isTasksHeading(heading)) return heading
    }
    return ""
  }
  property bool journalExists: false
  property string journalError: ""
  property string journalUri: ""
  property var todos: []
  property string pendingAdd: ""
  property var pendingDefer: null
  property var pendingEdit: null
  property string editingHeading: ""
  property int editingIndex: -1
  property bool pendingMonthRefresh: false
  property string pendingStatusDate: ""
  property var monthMarks: ({})
  property bool pendingMonthMarks: false

  // Pinned to today, not to the month being browsed — stepping through the
  // calendar does not change how much of the year is gone.
  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())

  // Memento mori, for anyone who goes looking: double-tapping the year bar
  // asks for a birth year and a life expectancy, and a second bar tracks one
  // against the other. A birth year rather than an age, so it keeps counting
  // on its own. Without one the bar stays hidden.
  readonly property int birthYear: Model.parseBirthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

  // Unset falls through to the locale's own first day, so a fresh install
  // starts out matching the rest of the desktop rather than a hardcoded
  // convention. Clicking the grid's "W" heading writes the choice back to
  // shell.json.
  readonly property int weekStart: Model.normalizedWeekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  // The interface is English throughout, so day names are not taken from the
  // system locale. Where the week starts still is: that is a regional
  // convention rather than a translation, and it stays overridable above.
  readonly property var labelLocale: Qt.locale("en_US")
  readonly property string nextWeekStartLabel: labelLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)


  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int cellWidth: Style.space(52)
  readonly property int cellHeight: Style.space(42)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)
  readonly property int calendarGridWidth: weekColumnWidth + gutterWidth + 7 * cellWidth + 8 * cellSpacing
  readonly property int todoDotSize: Style.space(4)
  readonly property int dayNumberHeight: Style.space(18)
  readonly property int dayNumberTop: Style.space(6)

  function open() {
    refresh()
    root.pendingTodoFocus = true
    root.todoFocusTries = 0
    root.controller.show()
    todoFocusTimer.restart()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
      root.tryFocusTodoInput()
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingLife) root.cancelEditingLife()
    if (root.journalDirty) root.saveJournalNow()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.today = new Date()
    root.goToToday()
  }

  function goToToday() {
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
    root.selectDayKey(root.todayKey)
    root.loadMonthMarks()
  }

  function selectDay(cell) {
    if (!cell || !cell.key) return
    var monthChanged = false
    if (!cell.inMonth) {
      monthChanged = cell.year !== root.viewYear || cell.month !== root.viewMonth
      root.viewYear = cell.year
      root.viewMonth = cell.month
    }
    root.selectDayKey(cell.key)
    if (monthChanged) root.loadMonthMarks()
  }

  function selectDayKey(key) {
    var next = String(key || "")
    if (next === "") return
    if (root.journalDirty && next !== root.selectedKey)
      root.saveJournalNow()
    if (next !== root.selectedKey) {
      root.tasksDoneExpanded = false
      root.sectionDoneExpanded = false
      root.cancelTodoEdit()
    }
    root.selectedKey = next
    // A new day owns the editor; don't let yesterday's dirty flag
    // swallow the snapshot that is about to arrive.
    if (next !== root.journalSynced)
      root.journalDirty = false
    root.loadJournal()
  }

  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function decodeFileUrl(urlString) {
    var path = String(urlString).replace(/^file:\/\//, "")
    try {
      return decodeURIComponent(path)
    } catch (e) {
      return path
    }
  }

  // Bundled with this plugin under bin/ (see journal/ for the Rust sources).
  readonly property string bundledJournalBin: root.hostArch === "" ? "" : root.decodeFileUrl(
    Qt.resolvedUrl("bin/obsidian-daily-qs-" + root.hostArch).toString())

  function journalPrefix() {
    return [root.journalBin, "--vault", root.vaultPath]
  }

  function journalCommand(args) {
    return root.journalPrefix().concat(args)
  }

  // Clap treats a following argv that starts with '-' as a flag unless the
  // value is attached (`--text=- [x] …`). Review bodies always start that way.
  function journalTextFlag(text) {
    return "--text=" + String(text == null ? "" : text)
  }

  function monthJournalCommand(args) {
    return root.journalPrefix().concat(["--heading", "tasks"]).concat(args)
  }

  function lineIsMarkdownHeading(line) {
    return /^#{1,6}\s+\S/.test(String(line || "").trim())
  }

  function notesHaveBody(notes) {
    return String(notes || "").split("\n").some(function(line) {
      var t = String(line || "").trim()
      if (t === "" || root.lineIsMarkdownHeading(t)) return false
      if (/^[-*+]\s+\[[ xX]\]/.test(t)) return false
      return true
    })
  }

  function isTasksHeading(title) {
    return String(title || "").toLowerCase().indexOf("tasks") >= 0
  }

  function tabGlyph(title) {
    var t = String(title || "").trim().toLowerCase()
    if (t.indexOf("nigh") >= 0) return "󰖔"
    if (t.indexOf("morning") >= 0 || t.indexOf("daily") >= 0 || /\bday\b/.test(t))
      return "󰖨"
    return ""
  }

  function draftForHeading(heading) {
    var key = String(heading || "")
    var table = root.sectionDrafts || {}
    return typeof table[key] === "string" ? table[key] : ""
  }

  function syncedForHeading(heading) {
    var key = String(heading || "")
    var table = root.sectionSynced || {}
    return typeof table[key] === "string" ? table[key] : ""
  }

  function setDraftForHeading(heading, text) {
    var key = String(heading || "")
    if (key === "") return
    var next = {}
    var prev = root.sectionDrafts || {}
    for (var existing in prev)
      next[existing] = prev[existing]
    next[key] = String(text || "")
    root.sectionDrafts = next
  }

  function setSyncedForHeading(heading, text) {
    var key = String(heading || "")
    if (key === "") return
    var next = {}
    var prev = root.sectionSynced || {}
    for (var existing in prev)
      next[existing] = prev[existing]
    next[key] = String(text || "")
    root.sectionSynced = next
  }

  function placeholderForTab(tab) {
    var heading = String(tab || "")
    if (heading === "") return root.journalExists ? "Write a note…" : "No note yet — type to create it"
    return heading + "…"
  }

  function splitCheckboxes(body) {
    var lines = String(body || "").split("\n")
    var todos = []
    var rest = []
    var re = /^(\s*)([-*+])\s+\[([ xX])\]\s+(.*)$/
    for (var i = 0; i < lines.length; i++) {
      var match = re.exec(lines[i])
      if (match) {
        todos.push({
          index: todos.length,
          checked: match[3] !== " ",
          text: match[4],
          indent: match[1],
          bullet: match[2]
        })
      } else {
        rest.push(lines[i])
      }
    }
    while (rest.length && String(rest[0]).trim() === "")
      rest.shift()
    while (rest.length && String(rest[rest.length - 1]).trim() === "")
      rest.pop()
    return { todos: todos, rest: rest.join("\n") }
  }

  function composeSectionBody(todos, rest) {
    var lines = []
    var list = todos || []
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      var mark = item.checked ? "x" : " "
      lines.push((item.indent || "") + (item.bullet || "-") + " [" + mark + "] " + item.text)
    }
    var prose = String(rest || "").replace(/^\n+/, "").replace(/\s+$/, "")
    if (prose !== "")
      lines.push(prose)
    return lines.join("\n")
  }

  function editorTextForTab(tab) {
    return root.splitCheckboxes(root.draftForHeading(tab)).rest
  }

  function sortedTodos(todos) {
    var list = todos || []
    var open = []
    var done = []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].checked) done.push(list[i])
      else open.push(list[i])
    }
    return open.concat(done)
  }

  function todosUnchecked(todos) {
    var list = todos || []
    var out = []
    for (var i = 0; i < list.length; i++) {
      if (!(list[i] && list[i].checked)) out.push(list[i])
    }
    return out
  }

  function todosChecked(todos) {
    var list = todos || []
    var out = []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].checked) out.push(list[i])
    }
    return out
  }

  readonly property var visibleSectionTodos: {
    var _ = root.sectionDrafts
    if (root.isTasksHeading(root.journalTab)) return []
    return root.splitCheckboxes(root.draftForHeading(root.journalTab)).todos
  }

  readonly property var visibleSectionOpen: root.todosUnchecked(root.visibleSectionTodos)
  readonly property var visibleSectionDone: root.todosChecked(root.visibleSectionTodos)

  readonly property var visibleTasksTodos: {
    var _ = root.sectionDrafts
    if (root.tasksHeading === "") return []
    return root.splitCheckboxes(root.draftForHeading(root.tasksHeading)).todos
  }

  readonly property var visibleTasksOpen: root.todosUnchecked(root.visibleTasksTodos)
  readonly property var visibleTasksDone: root.todosChecked(root.visibleTasksTodos)

  function tasksOpenDoneCounts() {
    var list = root.visibleTasksTodos || []
    var open = 0
    var done = 0
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].checked) done++
      else open++
    }
    return { open: open, done: done }
  }

  function tryFocusTodoInput() {
    if (!root.pendingTodoFocus || !root.opened) {
      todoFocusTimer.stop()
      return
    }
    root.todoFocusTries++
    if (todoInput && todoInput.visible && root.tasksHeading !== "") {
      todoInput.forceActiveFocus()
      if (todoInput.activeFocus) {
        root.pendingTodoFocus = false
        todoFocusTimer.stop()
        return
      }
    }
    if ((root.tabHeadings && root.tabHeadings.length > 0 && root.tasksHeading === "")
        || root.todoFocusTries > 20) {
      root.pendingTodoFocus = false
      todoFocusTimer.stop()
    }
  }

  function doneToggleLabel(count, expanded) {
    return (expanded ? "▾ " : "▸ ") + count + " done"
  }

  function firstNonTasksHeading(heads) {
    var list = heads || []
    for (var i = 0; i < list.length; i++) {
      var heading = String(list[i] || "").trim()
      if (heading !== "" && !root.isTasksHeading(heading))
        return heading
    }
    return ""
  }

  function setEditorFromTab(force) {
    if (!journalArea) return
    var next = root.editorTextForTab(root.journalTab)
    var sameDay = root.editorLoadedKey === root.selectedKey
    if (!force && journalArea.activeFocus && sameDay)
      return
    root.applyingJournal = true
    journalArea.text = next
    if (force || !sameDay)
      journalArea.cursorPosition = next.length
    if (journalFlick)
      journalFlick.contentY = 0
    root.editorLoadedKey = root.selectedKey
    root.applyingJournal = false
  }

  function headingKeyIn(list, heading) {
    var want = String(heading || "").trim().toLowerCase()
    if (want === "" || !list) return ""
    for (var i = 0; i < list.length; i++) {
      if (String(list[i] || "").trim().toLowerCase() === want)
        return String(list[i])
    }
    return ""
  }

  function applySections(templateHeads, sections) {
    var keepTab = ""
    var keepBody = ""
    if (journalArea && journalArea.activeFocus && root.editorLoadedKey === root.selectedKey
        && !root.isTasksHeading(root.journalTab)) {
      keepTab = root.journalTab
      keepBody = root.draftForHeading(keepTab)
    }
    var heads = []
    if (Array.isArray(templateHeads)) {
      for (var t = 0; t < templateHeads.length && heads.length < 16; t++) {
        var title = String(templateHeads[t] || "").trim()
        if (title !== "") heads.push(title)
      }
    }
    if (heads.length === 0 && Array.isArray(sections)) {
      for (var s = 0; s < sections.length && heads.length < 16; s++) {
        var sec = sections[s]
        if (!sec || typeof sec !== "object") continue
        var h = String(sec.heading || "").trim()
        if (h !== "") heads.push(h)
      }
    }
    root.tabHeadings = heads
    var drafts = {}
    for (var i = 0; i < heads.length; i++)
      drafts[heads[i]] = ""
    if (Array.isArray(sections)) {
      for (var j = 0; j < sections.length; j++) {
        var item = sections[j]
        if (!item || typeof item !== "object") continue
        var key = root.headingKeyIn(heads, item.heading)
        if (key === "") continue
        drafts[key] = typeof item.body === "string" ? item.body : ""
      }
    }
    if (keepTab !== "" && Object.prototype.hasOwnProperty.call(drafts, keepTab))
      drafts[keepTab] = keepBody
    var synced = {}
    for (var k in drafts)
      synced[k] = drafts[k]
    if (keepTab !== "" && Object.prototype.hasOwnProperty.call(synced, keepTab))
      synced[keepTab] = keepBody
    root.sectionDrafts = drafts
    root.sectionSynced = synced
    var currentTab = root.headingKeyIn(heads, root.journalTab)
    if (currentTab === "" || root.isTasksHeading(currentTab))
      root.journalTab = root.firstNonTasksHeading(heads)
    if (keepTab !== "") {
      root.journalDraft = journalArea.text
      root.journalSynced = keepBody
    } else {
      root.journalDraft = root.editorTextForTab(root.journalTab)
      root.journalSynced = root.syncedForHeading(root.journalTab)
    }
    root.setEditorFromTab(false)
    Qt.callLater(function() { root.tryFocusTodoInput() })
  }

  function selectJournalTab(tab) {
    var next = String(tab || "")
    if (next === "" || next === root.journalTab) return
    if (root.journalDirty) root.saveJournalNow()
    root.sectionDoneExpanded = false
    root.journalTab = next
    root.applyingJournal = true
    root.journalDraft = root.editorTextForTab(next)
    root.journalSynced = root.syncedForHeading(next)
    root.setEditorFromTab(true)
    root.applyingJournal = false
  }

  function resolveJournalBin() {
    var arch = root.hostArch
    var configured = String(setting("journalBin", "") || "").trim()
    var bundled = root.bundledJournalBin
    var prefix = ""
    if (configured !== "")
      prefix += "[ -x " + root.shellQuote(configured) + " ] && { printf '%s\\n' " + root.shellQuote(configured) + "; exit 0; }; "
    if (bundled !== "")
      prefix += "[ -x " + root.shellQuote(bundled) + " ] && { printf '%s\\n' " + root.shellQuote(bundled) + "; exit 0; }; "
    binProbe.command = ["bash", "-c",
      prefix +
      "arch=" + root.shellQuote(arch) + "; " +
      "command -v obsidian-daily-qs"]
    binProbe.running = true
  }

  function loadJournal() {
    if (root.journalBin === "" || root.vaultPath === "" || root.selectedKey === "") return
    root.pendingStatusDate = root.selectedKey
    root.pumpStatus()
  }

  function pumpStatus() {
    if (statusProc.running) return
    var date = root.pendingStatusDate !== "" ? root.pendingStatusDate : root.selectedKey
    root.pendingStatusDate = ""
    if (root.journalBin === "" || root.vaultPath === "" || date === "") return
    statusProc.command = root.journalCommand(["status", "--date", date])
    statusProc.running = true
  }

  function pad2(n) {
    return n < 10 ? "0" + n : String(n)
  }

  function loadMonthMarks() {
    if (root.journalBin === "" || root.vaultPath === "") return
    if (monthProc.running) {
      root.pendingMonthMarks = true
      return
    }
    var date = root.viewYear + "-" + root.pad2(root.viewMonth + 1) + "-01"
    monthProc.command = root.monthJournalCommand(["month", "--date", date])
    monthProc.running = true
  }

  function applyMonthLine(line) {
    var text = String(line || "").trim()
    if (text === "") return
    var parsed
    try { parsed = JSON.parse(text) } catch (e) { return }
    if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.days)) return
    var next = {}
    for (var i = 0; i < parsed.days.length; i++) {
      var item = parsed.days[i]
      if (!item || typeof item !== "object" || !item.date) continue
      next[String(item.date)] = {
        openCount: Number(item.openCount) || 0,
        doneCount: Number(item.doneCount) || 0,
        hasNotes: item.hasNotes === true
      }
    }
    root.monthMarks = next
  }

  function patchMonthMark(dateKey, openCount, doneCount, hasNotes) {
    var key = String(dateKey || "")
    if (key === "") return
    var next = {}
    var prev = root.monthMarks || {}
    for (var existing in prev)
      next[existing] = prev[existing]
    var prevMark = prev[key] || {}
    next[key] = {
      openCount: Math.max(0, Math.floor(Number(openCount) || 0)),
      doneCount: Math.max(0, Math.floor(Number(doneCount) || 0)),
      hasNotes: hasNotes === undefined ? prevMark.hasNotes === true : hasNotes === true
    }
    root.monthMarks = next
  }

  function todoDotCount(cell, marks) {
    if (!cell || !cell.key) return 0
    var table = marks || root.monthMarks
    var mark = table ? table[cell.key] : null
    if (!mark) return 0
    var n = Number(mark.openCount) || 0
    if (n < 1) return 0
    return Math.min(5, Math.floor(n))
  }

  function todoDotColor(cell) {
    if (cell && cell.key && cell.key < root.todayKey)
      return Color.accent
    if (cell && cell.inMonth)
      return Style.selectedStateColor(root.contentForeground, Color.accent)
    return Qt.darker(root.contentForeground, 1.9)
  }

  function dayHasNote(cell, marks) {
    if (!cell || !cell.key || !cell.inMonth) return false
    var table = marks || root.monthMarks
    var mark = table ? table[cell.key] : null
    return !!(mark && mark.hasNotes)
  }

  function dayCellTooltip(cell) {
    if (!cell || !cell.key) return ""
    var label = cell.today
      ? "Today"
      : Qt.formatDate(new Date(cell.year, cell.month, cell.day), "ddd d MMM")
    var n = 0
    var mark = root.monthMarks ? root.monthMarks[cell.key] : null
    if (mark) n = Number(mark.openCount) || 0
    var extra = []
    if (n > 0) {
      extra.push((cell.key < root.todayKey ? "overdue · " : "")
        + (n === 1 ? "1 open task" : n + " open tasks"))
    }
    if (root.dayHasNote(cell)) extra.push("has notes")
    return extra.length ? label + " · " + extra.join(" · ") : label
  }

  function todoRowTooltip() {
    return "Click to toggle · Right-click to edit"
  }

  function doneListTooltip(expanded, count) {
    var n = Number(count) || 0
    if (expanded) return "Hide completed"
    return n === 1 ? "Show 1 completed" : "Show " + n + " completed"
  }

  function saveJournalNow() {
    journalSaveTimer.stop()
    if (!root.journalDirty) return
    if (root.journalTab === "") return
    if (root.journalBin === "" || root.vaultPath === "") return
    var heading = root.journalTab
    var body = root.draftForHeading(heading)
    root.journalDirty = false
    root.journalSynced = body
    root.setSyncedForHeading(heading, body)
    notesProc.command = root.journalPrefix().concat([
      "--notes-heading", heading,
      "set-notes", "--date", root.selectedKey, root.journalTextFlag(body)
    ])
    notesProc.running = true
  }

  function openSelectedInObsidian() {
    if (root.journalDirty) root.saveJournalNow()
    if (root.journalBin === "" || root.vaultPath === "") return
    actionProc.command = root.journalCommand(["open", "--date", root.selectedKey])
    actionProc.running = true
  }

  function applyJournalLine(line) {
    var text = String(line || "").trim()
    if (text === "") return
    var parsed
    try { parsed = JSON.parse(text) } catch (e) { return }
    if (!parsed || typeof parsed !== "object") return
    if (parsed.date && String(parsed.date) !== root.selectedKey) return
    if (String(parsed.state || "") === "error") {
      root.journalError = String(parsed.error || "Unable to read journal")
      root.pendingMonthRefresh = false
      return
    }
    root.journalError = ""
    root.journalExists = parsed.exists === true
    root.journalUri = String(parsed.obsidianUri || "")
    var nextTodos = []
    if (Array.isArray(parsed.todos)) {
      for (var i = 0; i < parsed.todos.length; i++) {
        var item = parsed.todos[i]
        if (!item || typeof item !== "object") continue
        var lineNo = Number(item.line)
        if (!isFinite(lineNo) || lineNo < 1) continue
        var depth = Number(item.depth)
        if (!isFinite(depth) || depth < 0) depth = 0
        nextTodos.push({
          line: Math.floor(lineNo),
          checked: item.checked === true,
          text: String(item.text || ""),
          depth: Math.min(32, Math.floor(depth))
        })
      }
    }
    root.todos = nextTodos
    var keepEditor = journalArea && journalArea.activeFocus && root.editorLoadedKey === root.selectedKey
    root.applyingJournal = true
    root.applySections(parsed.templateHeadings, parsed.sections)
    root.journalNotes = typeof parsed.notes === "string" ? parsed.notes : ""
    if (!keepEditor)
      root.journalDirty = false
    root.applyingJournal = false
    var dateKey = parsed.date ? String(parsed.date) : root.selectedKey
    if (dateKey !== "") {
      var counts = root.tasksOpenDoneCounts()
      root.patchMonthMark(dateKey, counts.open, counts.done, root.anySectionHasNotes())
    }
    if (root.pendingMonthRefresh) {
      root.pendingMonthRefresh = false
      root.loadMonthMarks()
    }
  }

  function anySectionHasNotes() {
    var drafts = root.sectionDrafts || {}
    for (var key in drafts) {
      if (root.notesHaveBody(root.splitCheckboxes(drafts[key]).rest))
        return true
    }
    return false
  }

  function addTodo() {
    var text = String(todoInput.text || "").trim()
    if (text === "") return
    todoInput.text = ""
    if (root.journalDirty) {
      root.pendingAdd = text
      root.saveJournalNow()
      return
    }
    root.submitAdd(text)
  }

  function submitAdd(text) {
    var trimmed = String(text || "").trim()
    var heading = root.tasksHeading !== "" ? root.tasksHeading : root.journalTab
    if (trimmed === "" || heading === "" || root.journalBin === "" || root.vaultPath === "" || root.selectedKey === "")
      return
    var split = root.splitCheckboxes(root.draftForHeading(heading))
    split.todos.push({
      index: split.todos.length,
      checked: false,
      text: trimmed,
      indent: "",
      bullet: "-"
    })
    root.writeSection(heading, root.composeSectionBody(split.todos, split.rest))
  }

  function writeSection(heading, body) {
    root.setDraftForHeading(heading, body)
    root.setSyncedForHeading(heading, body)
    if (heading === root.journalTab) {
      root.journalDraft = root.editorTextForTab(heading)
      root.journalSynced = body
      root.journalDirty = false
      journalSaveTimer.stop()
    }
    if (root.journalBin === "" || root.vaultPath === "") return
    notesProc.command = root.journalPrefix().concat([
      "--notes-heading", heading,
      "set-notes", "--date", root.selectedKey, root.journalTextFlag(body)
    ])
    notesProc.running = true
  }

  function toggleTodo(line, text) {
    var n = Number(line)
    if (!isFinite(n) || n < 1) return
    if (root.journalBin === "" || root.vaultPath === "" || root.selectedKey === "") return
    var args = root.journalCommand(["toggle", "--date", root.selectedKey, "--line", String(Math.floor(n))])
    if (typeof text === "string" && text !== "")
      args.push("--expect-text", text)
    actionProc.command = args
    actionProc.running = true
  }

  function toggleSectionTodo(index) {
    var n = Number(index)
    if (!isFinite(n) || n < 0) return
    var tab = root.journalTab
    if (tab === "") return
    var split = root.splitCheckboxes(root.draftForHeading(tab))
    if (n >= split.todos.length) return
    var rest = journalArea ? journalArea.text : split.rest
    var todos = []
    for (var i = 0; i < split.todos.length; i++) {
      var item = split.todos[i]
      todos.push({
        index: item.index,
        checked: i === n ? !item.checked : item.checked,
        text: item.text,
        indent: item.indent,
        bullet: item.bullet
      })
    }
    root.writeSection(tab, root.composeSectionBody(todos, rest))
  }

  function togglePinnedTodo(index) {
    var n = Number(index)
    if (!isFinite(n) || n < 0) return
    var heading = root.tasksHeading
    if (heading === "") return
    var split = root.splitCheckboxes(root.draftForHeading(heading))
    if (n >= split.todos.length) return
    var todos = []
    for (var i = 0; i < split.todos.length; i++) {
      var item = split.todos[i]
      todos.push({
        index: item.index,
        checked: i === n ? !item.checked : item.checked,
        text: item.text,
        indent: item.indent,
        bullet: item.bullet
      })
    }
    root.writeSection(heading, root.composeSectionBody(todos, split.rest))
  }

  function isEditingTodo(heading, index) {
    return root.editingHeading !== "" && root.editingHeading === String(heading || "")
      && root.editingIndex === Number(index)
  }

  function startTodoEdit(heading, index) {
    var h = String(heading || "")
    var n = Number(index)
    if (h === "" || !isFinite(n) || n < 0) return
    root.editingHeading = h
    root.editingIndex = n
  }

  function cancelTodoEdit() {
    root.editingHeading = ""
    root.editingIndex = -1
  }

  function commitTodoEdit(text) {
    var heading = root.editingHeading
    var n = root.editingIndex
    var trimmed = String(text || "").trim()
    root.cancelTodoEdit()
    if (heading === "" || !isFinite(n) || n < 0) return
    if (trimmed === "") return
    if (root.journalDirty) {
      root.pendingEdit = { heading: heading, index: n, text: trimmed }
      root.saveJournalNow()
      return
    }
    root.submitTodoEdit(heading, n, trimmed)
  }

  function submitTodoEdit(heading, index, text) {
    var h = String(heading || "")
    var n = Number(index)
    var trimmed = String(text || "").trim()
    if (h === "" || trimmed === "" || !isFinite(n) || n < 0) return
    var split = root.splitCheckboxes(root.draftForHeading(h))
    if (n >= split.todos.length) return
    if (String(split.todos[n].text || "") === trimmed) return
    var rest = (h === root.journalTab && journalArea) ? journalArea.text : split.rest
    var todos = []
    for (var i = 0; i < split.todos.length; i++) {
      var item = split.todos[i]
      todos.push({
        index: item.index,
        checked: item.checked,
        text: i === n ? trimmed : item.text,
        indent: item.indent,
        bullet: item.bullet
      })
    }
    root.writeSection(h, root.composeSectionBody(todos, rest))
  }

  function deferTodo(heading, index) {
    var n = Number(index)
    if (!isFinite(n) || n < 0) return
    var h = String(heading || "")
    if (h === "") return
    var split = root.splitCheckboxes(root.draftForHeading(h))
    if (n >= split.todos.length) return
    var item = split.todos[n]
    if (!item || item.checked) return
    if (root.journalDirty) {
      root.pendingDefer = { heading: h, index: n }
      root.saveJournalNow()
      return
    }
    root.submitDefer(h, item.text)
  }

  function submitDefer(heading, text) {
    var h = String(heading || "")
    var trimmed = String(text || "").trim()
    if (h === "" || trimmed === "") return
    if (root.journalBin === "" || root.vaultPath === "" || root.selectedKey === "") return
    root.pendingMonthRefresh = true
    actionProc.command = root.journalPrefix().concat([
      "--notes-heading", h,
      "defer", "--date", root.selectedKey, root.journalTextFlag(trimmed)
    ])
    actionProc.running = true
  }

  function onJournalEdited(text) {
    if (root.applyingJournal) return
    var tab = root.journalTab
    if (tab === "") return
    var next = root.composeSectionBody(root.splitCheckboxes(root.draftForHeading(tab)).todos, text)
    root.setDraftForHeading(tab, next)
    root.journalDraft = text
    root.journalDirty = (next !== root.syncedForHeading(tab))
    if (root.journalDirty) journalSaveTimer.restart()
    else journalSaveTimer.stop()
  }

  Component.onCompleted: unameProc.running = true

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
    root.loadMonthMarks()
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value. With no
  // writable entry (the widget is not in the layout) it stays a session-only
  // preference rather than doing nothing. The host widget builds its own
  // entry when the label format is cycled, so it has to be kept in step or
  // it would write this key straight back out from a stale copy.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  function startEditingLife() {
    root.editingLife = true
    Qt.callLater(function() {
      bornField.text = root.birthYear > 0 ? String(root.birthYear) : ""
      expectancyField.text = String(root.lifeExpectancy)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }

  function cancelEditingLife() {
    root.editingLife = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Shared by both fields: Tab hops to the other one, Enter commits the pair,
  // Escape drops the lot.
  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  // Double-tapping the life bar puts it away again. The expectancy stays in
  // the config so setting a birth year again brings your own number back
  // rather than the default.
  function clearLife() {
    if (root.birthYear <= 0) return
    persistSettings({ birthYear: 0 })
  }

  function commitLife() {
    var born = Model.parseBirthYear(bornField.text, today.getFullYear())
    var span = Model.parseLifeExpectancy(expectancyField.text)
    if (born !== root.birthYear || span !== root.lifeExpectancy)
      persistSettings({ birthYear: born, lifeExpectancy: span })
    cancelEditingLife()
  }

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  // English short day names, matching the rest of the interface.
  function weekdayLabel(weekday) {
    return String(labelLocale.dayName(weekday, Locale.ShortFormat)).toUpperCase()
  }

  Timer {
    id: todoFocusTimer
    interval: 50
    repeat: true
    onTriggered: root.tryFocusTodoInput()
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      root.today = clock.date
      if (followToday) root.goToToday()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(
      Math.max(Style.space(440), root.calendarGridWidth + panel.padding * 2 + Style.space(16)))
    contentHeight: panel.fittedContentHeight(calendarColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife || journalArea.activeFocus || todoInput.activeFocus || root.editingIndex >= 0
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
      }

      Timer {
        id: journalSaveTimer
        interval: 450
        repeat: false
        onTriggered: root.saveJournalNow()
      }

      Column {
        id: calendarColumn
        z: 3
        width: parent.width
        spacing: Style.space(8)

          // ---- Hero: today, centered. Clicking it always lands on
          //      today's cell and today's Obsidian journal, whether the
          //      grid was on another month or just another day.
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              Text {
                // Baseline-aligned, not center-aligned: "July 26" carries a
                // descender, so centering the two boxes leaves the icon
                // sitting visibly low against the digits.
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.*
                // scale. Sized so the glyph reads at the cap height of the
                // date beside it rather than towering over it.
                font.pixelSize: 48
              }

              Text {
                id: heroDate
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(root.today, "MMMM d")
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 52
                font.bold: true
              }
            }

            // Same hit-target as the "W" toggle and day cells: a MouseArea
            // filling this row, stacked above the glyphs. The old overlay
            // on heroRow's box lost to KeyboardPanel's card swallow.
            MouseArea {
              id: heroMouse
              anchors.fill: parent
              z: 2
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.today = new Date()
                root.goToToday()
              }

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Jump to today"
                fontFamily: root.contentFontFamily
              }
            }
          }

          // ---- Year progress, doubling as the rule under the hero:
          //      a plain hairline said nothing, and whole days done
          //      over days in the year says the same thing louder.
          Item {
            width: parent.width
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.startEditingLife()
              }

              MouseArea {
                id: yearMouse
                anchors.fill: parent
                enabled: !root.editingLife
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: yearMouse.containsMouse
                  text: "Year progress · Double-tap to set a life span"
                  fontFamily: root.contentFontFamily
                }
              }

              Row {
                visible: root.editingLife
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BORN"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "year"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }

                  PanelToolTip {
                    visible: bornField.hovered && !bornField.activeFocus
                    text: "Birth year"
                    fontFamily: root.contentFontFamily
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: 0
                  leftPadding: Style.space(6)
                  text: "LIVE TO"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, bornField) }

                  PanelToolTip {
                    visible: expectancyField.hovered && !expectancyField.activeFocus
                    text: "Life expectancy"
                    fontFamily: root.contentFontFamily
                  }
                }
              }

              Text {
                id: yearLabel
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.today.getFullYear()
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: yearPercent
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.yearDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                visible: !root.editingLife
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // ---- Memento mori. Only here once someone has gone looking and
          //      given an age; the same rail as the year above it, measured
          //      against a nominal lifetime.
          Item {
            visible: root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                id: lifeLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "LIFE"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: lifePercent
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.lifeDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                anchors.left: lifeLabel.right
                anchors.right: lifePercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              TapHandler {
                onDoubleTapped: root.clearLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Life progress · Double-tap to clear"
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }

          // ---- Month grid: week numbers down a gutter on the left, then
          //      the seven day columns. Always six rows, so the popup is
          //      exactly as tall in February as it is in August.
          Item {
            width: parent.width
            height: gridColumn.y + gridColumn.height

            WheelHandler {
              target: gridColumn
              acceptedButtons: Qt.NoButton
              onWheel: function(event) {
                // Horizontal wheels and touchpad side-scrolls report y === 0;
                // without this they would every one read as "next month".
                if (event.angleDelta.y === 0) return
                root.moveMonth(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            Column {
              id: gridColumn
              // The meter above is a solid rule; the grid needs room to
              // read as its own block rather than hanging off it.
              y: Style.space(18)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headerRow
                spacing: root.cellSpacing

                // The week-number heading doubles as the week-start toggle.
                // It is the one control in the panel whose meaning is not
                // self-evident, so it carries a tooltip naming the day the
                // click will switch to.
                Rectangle {
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "W"
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }

                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }

                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: "Start weeks on " + root.nextWeekStartLabel
                    fontFamily: root.contentFontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Item {
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)

                    Text {
                      anchors.fill: parent
                      textFormat: Text.PlainText
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter
                      text: root.weekdayLabel(modelData)
                      color: Qt.darker(root.contentForeground, 1.5)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                      font.bold: true
                    }

                    MouseArea {
                      id: weekdayMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      acceptedButtons: Qt.NoButton
                    }

                    PanelToolTip {
                      visible: weekdayMouse.containsMouse
                      text: root.labelLocale.dayName(modelData, Locale.LongFormat)
                      fontFamily: root.contentFontFamily
                    }
                  }
                }
              }

              // Same hit-target pattern as the "W" week-start toggle above:
              // a MouseArea filling each cell. A wrapping overlay never won
              // against KeyboardPanel's card swallow MouseArea.
              Column {
                id: weeksCol
                spacing: root.cellSpacing

                Repeater {
                  model: root.weeks

                  Row {
                    required property var modelData
                    spacing: root.cellSpacing

                    Item {
                      width: root.weekColumnWidth
                      height: root.cellHeight

                      Text {
                        anchors.fill: parent
                        textFormat: Text.PlainText
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        text: modelData.week
                        color: Qt.darker(root.contentForeground, 1.9)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        id: weekNumMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                      }

                      PanelToolTip {
                        visible: weekNumMouse.containsMouse
                        text: "ISO week " + modelData.week
                        fontFamily: root.contentFontFamily
                      }
                    }

                    Item {
                      width: root.gutterWidth
                      height: root.cellHeight
                    }

                    Repeater {
                      model: modelData.days

                      Rectangle {
                        id: dayCell
                        required property var modelData
                        readonly property var day: modelData
                        readonly property bool selected: day && day.key === root.selectedKey
                        readonly property bool hovered: dayMouse.containsMouse || (day && day.key === root.hoveredKey)
                        readonly property int todoDots: root.todoDotCount(day, root.monthMarks)
                        readonly property bool hasNote: root.dayHasNote(day, root.monthMarks)

                        width: root.cellWidth
                        height: root.cellHeight
                        radius: Style.cornerRadius
                        color: selected || hovered
                          ? Style.hoverFillFor(root.contentForeground, Color.accent)
                          : "transparent"
                        border.width: (day && day.today || selected) ? Style.spacing.hairline : 0
                        border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                        Text {
                          id: dayLabel
                          textFormat: Text.PlainText
                          x: 0
                          y: root.dayNumberTop
                          width: parent.width
                          height: root.dayNumberHeight
                          horizontalAlignment: Text.AlignHCenter
                          verticalAlignment: Text.AlignVCenter
                          text: day ? day.day : ""
                          color: {
                            if (!(day && day.inMonth))
                              return Qt.darker(root.contentForeground, 2.2)
                            if (dayCell.hasNote)
                              return "#ffffff"
                            if (day.weekend)
                              return Qt.darker(root.contentForeground, 1.45)
                            return root.contentForeground
                          }
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                          font.bold: (day && day.today) || selected || dayCell.hasNote
                        }

                        Item {
                          x: 0
                          y: root.dayNumberTop + root.dayNumberHeight + Style.space(2)
                          width: parent.width
                          height: root.todoDotSize

                          Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(2)

                            Repeater {
                              model: dayCell.todoDots

                              Rectangle {
                                required property int index
                                width: root.todoDotSize
                                height: root.todoDotSize
                                radius: width / 2
                                color: root.todoDotColor(day)
                              }
                            }
                          }
                        }

                        MouseArea {
                          id: dayMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          z: 2
                          onClicked: root.selectDay(day)
                          onEntered: root.hoveredKey = day && day.key ? day.key : ""
                          onExited: if (root.hoveredKey === (day && day.key ? day.key : "")) root.hoveredKey = ""

                          PanelToolTip {
                            visible: dayMouse.containsMouse && day
                            text: root.dayCellTooltip(day)
                            fontFamily: root.contentFontFamily
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // ---- Month stepping, spanning the grid it drives. The chevrons
          //      sit on the grid's outer bounds, the same edges the year
          //      rail above uses, so the row reads as the panel's other
          //      full-width rail instead of a cluster floating in space.
          //      The label is centered and fixed-width, so it holds still
          //      from "MAY" to "SEPTEMBER".
          Item {
            width: parent.width
            height: monthNav.height

            Item {
              id: monthNav
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: monthLabel.implicitHeight + Style.space(10)

              Text {
                id: monthLabel
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                // Fixed width so the chevrons hold still between a
                // "MAY 2026" and a "SEPTEMBER 2026".
                width: Style.space(130)
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatDate(root.viewDate, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                // Pulled out by the button's own padding so the glyph, not
                // its hit box, lines up with the "2026" on the year rail.
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(1)
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator {
              width: parent.width
              foreground: root.contentForeground
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.tasksHeading !== ""

              TextField {
                id: todoInput
                width: parent.width
                placeholderText: "Add a todo… (Enter)"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                onAccepted: root.addTodo()
                Keys.onEscapePressed: root.close()

                PanelToolTip {
                  visible: todoInput.hovered && !todoInput.activeFocus
                  text: "Add a todo (Enter)"
                  fontFamily: root.contentFontFamily
                }
              }

              Repeater {
                model: root.visibleTasksOpen

                Rectangle {
                  required property var modelData
                  readonly property bool editing: root.isEditingTodo(root.tasksHeading, modelData.index)
                  width: calendarColumn.width
                  implicitHeight: (editing ? pinnedTodoEdit.implicitHeight : pinnedTodoLabel.implicitHeight) + Style.space(4)
                  radius: Style.cornerRadius
                  color: pinnedTodoMouse.containsMouse || editing
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  MouseArea {
                    id: pinnedTodoMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function(mouse) {
                      if (mouse.button === Qt.RightButton) {
                        root.startTodoEdit(root.tasksHeading, modelData.index)
                        return
                      }
                      if (editing) return
                      root.togglePinnedTodo(modelData.index)
                    }

                    PanelToolTip {
                      visible: pinnedTodoMouse.containsMouse && !pinnedDeferMouse.containsMouse && !editing
                      text: root.todoRowTooltip()
                      fontFamily: root.contentFontFamily
                    }
                  }

                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(22)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    BorderSurface {
                      width: Style.space(16)
                      height: Style.space(16)
                      anchors.verticalCenter: parent.verticalCenter
                      radius: Math.max(2, Style.cornerRadius * 0.45)
                      color: modelData.checked
                        ? Style.selectedFillFor(root.contentForeground, Color.accent)
                        : "transparent"
                      borderSpec: Border.controlSpec(
                        modelData.checked ? "selected" : "normal",
                        root.contentForeground,
                        Color.accent)

                      Text {
                        anchors.centerIn: parent
                        visible: modelData.checked === true
                        text: "\u2713"
                        textFormat: Text.PlainText
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }

                    Text {
                      id: pinnedTodoLabel
                      visible: !editing
                      width: parent.width - Style.space(24)
                      text: modelData.text
                      textFormat: Text.PlainText
                      color: modelData.checked
                        ? Qt.darker(root.contentForeground, 1.6)
                        : root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.strikeout: modelData.checked === true
                      wrapMode: Text.WordWrap
                    }

                    TextField {
                      id: pinnedTodoEdit
                      visible: editing
                      width: parent.width - Style.space(24)
                      foreground: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      verticalPadding: Style.space(2)
                      horizontalPadding: Style.space(6)
                      onVisibleChanged: {
                        if (!visible) return
                        text = String(modelData.text || "")
                        Qt.callLater(function() {
                          pinnedTodoEdit.forceActiveFocus()
                          pinnedTodoEdit.selectAll()
                        })
                      }
                      onAccepted: root.commitTodoEdit(text)
                      onEditingFinished: {
                        if (root.isEditingTodo(root.tasksHeading, modelData.index))
                          root.commitTodoEdit(text)
                      }
                      Keys.onEscapePressed: function(event) {
                        root.cancelTodoEdit()
                        event.accepted = true
                      }
                    }
                  }

                  Item {
                    visible: !editing
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(22)
                    height: parent.height
                    z: 2

                    Text {
                      anchors.centerIn: parent
                      text: "\u2192"
                      textFormat: Text.PlainText
                      color: pinnedDeferMouse.containsMouse
                        ? root.contentForeground
                        : Qt.darker(root.contentForeground, 1.5)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                    }

                    MouseArea {
                      id: pinnedDeferMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.deferTodo(root.tasksHeading, modelData.index)
                    }

                    PanelToolTip {
                      visible: pinnedDeferMouse.containsMouse
                      text: "Move to tomorrow"
                      fontFamily: root.contentFontFamily
                    }
                  }
                }
              }

              Rectangle {
                visible: root.visibleTasksDone.length > 0
                width: parent.width
                implicitHeight: tasksDoneLabel.implicitHeight + Style.space(4)
                radius: Style.cornerRadius
                color: tasksDoneMouse.containsMouse
                  ? Style.hoverFillFor(root.contentForeground, Color.accent)
                  : "transparent"

                MouseArea {
                  id: tasksDoneMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.tasksDoneExpanded = !root.tasksDoneExpanded
                }

                PanelToolTip {
                  visible: tasksDoneMouse.containsMouse
                  text: root.doneListTooltip(root.tasksDoneExpanded, root.visibleTasksDone.length)
                  fontFamily: root.contentFontFamily
                }

                Text {
                  id: tasksDoneLabel
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.doneToggleLabel(root.visibleTasksDone.length, root.tasksDoneExpanded)
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }
              }

              Repeater {
                model: root.tasksDoneExpanded ? root.visibleTasksDone : []

                Rectangle {
                  required property var modelData
                  readonly property bool editing: root.isEditingTodo(root.tasksHeading, modelData.index)
                  width: calendarColumn.width
                  implicitHeight: (editing ? pinnedDoneEdit.implicitHeight : pinnedDoneLabel.implicitHeight) + Style.space(4)
                  radius: Style.cornerRadius
                  color: pinnedDoneMouse.containsMouse || editing
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  MouseArea {
                    id: pinnedDoneMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function(mouse) {
                      if (mouse.button === Qt.RightButton) {
                        root.startTodoEdit(root.tasksHeading, modelData.index)
                        return
                      }
                      if (editing) return
                      root.togglePinnedTodo(modelData.index)
                    }

                    PanelToolTip {
                      visible: pinnedDoneMouse.containsMouse && !editing
                      text: root.todoRowTooltip()
                      fontFamily: root.contentFontFamily
                    }
                  }

                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    BorderSurface {
                      width: Style.space(16)
                      height: Style.space(16)
                      anchors.verticalCenter: parent.verticalCenter
                      radius: Math.max(2, Style.cornerRadius * 0.45)
                      color: Style.selectedFillFor(root.contentForeground, Color.accent)
                      borderSpec: Border.controlSpec(
                        "selected",
                        root.contentForeground,
                        Color.accent)

                      Text {
                        anchors.centerIn: parent
                        text: "\u2713"
                        textFormat: Text.PlainText
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }

                    Text {
                      id: pinnedDoneLabel
                      visible: !editing
                      width: parent.width - Style.space(24)
                      text: modelData.text
                      textFormat: Text.PlainText
                      color: Qt.darker(root.contentForeground, 1.6)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.strikeout: true
                      wrapMode: Text.WordWrap
                    }

                    TextField {
                      id: pinnedDoneEdit
                      visible: editing
                      width: parent.width - Style.space(24)
                      foreground: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      verticalPadding: Style.space(2)
                      horizontalPadding: Style.space(6)
                      onVisibleChanged: {
                        if (!visible) return
                        text = String(modelData.text || "")
                        Qt.callLater(function() {
                          pinnedDoneEdit.forceActiveFocus()
                          pinnedDoneEdit.selectAll()
                        })
                      }
                      onAccepted: root.commitTodoEdit(text)
                      onEditingFinished: {
                        if (root.isEditingTodo(root.tasksHeading, modelData.index))
                          root.commitTodoEdit(text)
                      }
                      Keys.onEscapePressed: function(event) {
                        root.cancelTodoEdit()
                        event.accepted = true
                      }
                    }
                  }
                }
              }
            }

            Text {
              width: parent.width
              visible: root.journalError !== ""
              text: root.journalError
              textFormat: Text.PlainText
              color: Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.journalTabs

                Rectangle {
                  required property var modelData
                  readonly property bool selected: modelData && modelData.key === root.journalTab
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.preferredWidth: 1
                  Layout.minimumWidth: Style.space(28)
                  Layout.preferredHeight: Style.space(28)
                  Layout.alignment: Qt.AlignVCenter
                  radius: Style.cornerRadius
                  color: selected || tabMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"
                  border.width: Style.spacing.hairline
                  border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                  Text {
                    id: tabLabel
                    anchors.centerIn: parent
                    width: parent.width - Style.space(8)
                    text: modelData ? modelData.label : ""
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                    color: selected
                      ? root.contentForeground
                      : Qt.darker(root.contentForeground, 1.45)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: selected
                  }

                  MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectJournalTab(modelData.key)
                  }

                  PanelToolTip {
                    visible: tabMouse.containsMouse && modelData && modelData.tooltip
                    text: modelData ? modelData.tooltip : ""
                    fontFamily: root.contentFontFamily
                  }
                }
              }

              Item {
                visible: root.journalDirty
                implicitWidth: savingLabel.implicitWidth
                implicitHeight: savingLabel.implicitHeight
                Layout.alignment: Qt.AlignVCenter

                Text {
                  id: savingLabel
                  text: "Saving…"
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: savingMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                }

                PanelToolTip {
                  visible: savingMouse.containsMouse
                  text: "Writing to the daily note"
                  fontFamily: root.contentFontFamily
                }
              }

              Rectangle {
                Layout.preferredWidth: Style.space(28)
                Layout.preferredHeight: Style.space(28)
                Layout.minimumWidth: Style.space(28)
                Layout.maximumWidth: Style.space(28)
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignVCenter
                radius: Style.cornerRadius
                color: openMouse.containsMouse
                  ? Style.hoverFillFor(root.contentForeground, Color.accent)
                  : "transparent"
                border.width: 0

                Text {
                  anchors.centerIn: parent
                  anchors.verticalCenterOffset: Style.space(2)
                  text: "\u2197"
                  textFormat: Text.PlainText
                  color: openMouse.containsMouse
                    ? root.contentForeground
                    : Qt.darker(root.contentForeground, 1.45)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  id: openMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openSelectedInObsidian()
                }

                PanelToolTip {
                  visible: openMouse.containsMouse
                  text: "Open this day in Obsidian"
                  fontFamily: root.contentFontFamily
                }
              }
            }
            Item {
              id: journalFrame
              width: parent.width
              height: Style.space(180)

              BorderSurface {
                anchors.fill: parent
                color: "transparent"
                borderSpec: Border.controlSpec(
                  journalArea.activeFocus ? "selected" : "normal",
                  root.contentForeground,
                  Color.accent)
              }

              Flickable {
                id: journalFlick
                anchors.fill: parent
                anchors.margins: Style.space(6)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                contentWidth: width
                contentHeight: journalArea.height
                interactive: contentHeight > height

                TextArea {
                  id: journalArea
                  width: journalFlick.width
                  height: Math.max(journalFlick.height, contentHeight + topPadding + bottomPadding)
                  wrapMode: TextEdit.Wrap
                  selectByMouse: true
                  persistentSelection: true
                  color: root.contentForeground
                  placeholderText: root.placeholderForTab(root.journalTab)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  background: Item {}
                  Component.onCompleted: text = root.journalDraft
                  onTextChanged: {
                    if (text !== root.journalDraft)
                      root.onJournalEdited(text)
                  }
                  Keys.onEscapePressed: {
                    if (root.journalDirty) root.saveJournalNow()
                    root.close()
                  }

                  PanelToolTip {
                    visible: journalArea.hovered && !journalArea.activeFocus
                    text: root.journalTab !== ""
                      ? "Notes — " + root.journalTab
                      : "Daily notes"
                    fontFamily: root.contentFontFamily
                  }
                }

                ScrollBar.vertical: ScrollBar {
                  policy: journalFlick.contentHeight > journalFlick.height
                    ? ScrollBar.AlwaysOn
                    : ScrollBar.AlwaysOff
                }
              }

              WheelHandler {
                acceptedButtons: Qt.NoButton
                onWheel: function(event) {
                  var maxY = Math.max(0, journalFlick.contentHeight - journalFlick.height)
                  if (maxY <= 0) return
                  var delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 4
                  if (delta === 0) return
                  journalFlick.contentY = Math.max(0, Math.min(maxY, journalFlick.contentY - delta))
                  event.accepted = true
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.visibleSectionTodos.length > 0

              Repeater {
                model: root.visibleSectionOpen

                Rectangle {
                  required property var modelData
                  readonly property bool editing: root.isEditingTodo(root.journalTab, modelData.index)
                  width: calendarColumn.width
                  implicitHeight: (editing ? todoEdit.implicitHeight : todoLabel.implicitHeight) + Style.space(4)
                  radius: Style.cornerRadius
                  color: todoMouse.containsMouse || editing
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  MouseArea {
                    id: todoMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function(mouse) {
                      if (mouse.button === Qt.RightButton) {
                        root.startTodoEdit(root.journalTab, modelData.index)
                        return
                      }
                      if (editing) return
                      root.toggleSectionTodo(modelData.index)
                    }

                    PanelToolTip {
                      visible: todoMouse.containsMouse && !sectionDeferMouse.containsMouse && !editing
                      text: root.todoRowTooltip()
                      fontFamily: root.contentFontFamily
                    }
                  }

                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(22)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    BorderSurface {
                      width: Style.space(16)
                      height: Style.space(16)
                      anchors.verticalCenter: parent.verticalCenter
                      radius: Math.max(2, Style.cornerRadius * 0.45)
                      color: modelData.checked
                        ? Style.selectedFillFor(root.contentForeground, Color.accent)
                        : "transparent"
                      borderSpec: Border.controlSpec(
                        modelData.checked ? "selected" : "normal",
                        root.contentForeground,
                        Color.accent)

                      Text {
                        anchors.centerIn: parent
                        visible: modelData.checked === true
                        text: "\u2713"
                        textFormat: Text.PlainText
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }

                    Text {
                      id: todoLabel
                      visible: !editing
                      width: parent.width - Style.space(24)
                      text: modelData.text
                      textFormat: Text.PlainText
                      color: modelData.checked
                        ? Qt.darker(root.contentForeground, 1.6)
                        : root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.strikeout: modelData.checked === true
                      wrapMode: Text.WordWrap
                    }

                    TextField {
                      id: todoEdit
                      visible: editing
                      width: parent.width - Style.space(24)
                      foreground: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      verticalPadding: Style.space(2)
                      horizontalPadding: Style.space(6)
                      onVisibleChanged: {
                        if (!visible) return
                        text = String(modelData.text || "")
                        Qt.callLater(function() {
                          todoEdit.forceActiveFocus()
                          todoEdit.selectAll()
                        })
                      }
                      onAccepted: root.commitTodoEdit(text)
                      onEditingFinished: {
                        if (root.isEditingTodo(root.journalTab, modelData.index))
                          root.commitTodoEdit(text)
                      }
                      Keys.onEscapePressed: function(event) {
                        root.cancelTodoEdit()
                        event.accepted = true
                      }
                    }
                  }

                  Item {
                    visible: !editing
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(22)
                    height: parent.height
                    z: 2

                    Text {
                      anchors.centerIn: parent
                      text: "\u2192"
                      textFormat: Text.PlainText
                      color: sectionDeferMouse.containsMouse
                        ? root.contentForeground
                        : Qt.darker(root.contentForeground, 1.5)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                    }

                    MouseArea {
                      id: sectionDeferMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.deferTodo(root.journalTab, modelData.index)
                    }

                    PanelToolTip {
                      visible: sectionDeferMouse.containsMouse
                      text: "Move to tomorrow"
                      fontFamily: root.contentFontFamily
                    }
                  }
                }
              }

              Rectangle {
                visible: root.visibleSectionDone.length > 0
                width: parent.width
                implicitHeight: sectionDoneLabel.implicitHeight + Style.space(4)
                radius: Style.cornerRadius
                color: sectionDoneMouse.containsMouse
                  ? Style.hoverFillFor(root.contentForeground, Color.accent)
                  : "transparent"

                MouseArea {
                  id: sectionDoneMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.sectionDoneExpanded = !root.sectionDoneExpanded
                }

                PanelToolTip {
                  visible: sectionDoneMouse.containsMouse
                  text: root.doneListTooltip(root.sectionDoneExpanded, root.visibleSectionDone.length)
                  fontFamily: root.contentFontFamily
                }

                Text {
                  id: sectionDoneLabel
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.doneToggleLabel(root.visibleSectionDone.length, root.sectionDoneExpanded)
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }
              }

              Repeater {
                model: root.sectionDoneExpanded ? root.visibleSectionDone : []

                Rectangle {
                  required property var modelData
                  readonly property bool editing: root.isEditingTodo(root.journalTab, modelData.index)
                  width: calendarColumn.width
                  implicitHeight: (editing ? doneTodoEdit.implicitHeight : doneTodoLabel.implicitHeight) + Style.space(4)
                  radius: Style.cornerRadius
                  color: doneTodoMouse.containsMouse || editing
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  MouseArea {
                    id: doneTodoMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function(mouse) {
                      if (mouse.button === Qt.RightButton) {
                        root.startTodoEdit(root.journalTab, modelData.index)
                        return
                      }
                      if (editing) return
                      root.toggleSectionTodo(modelData.index)
                    }

                    PanelToolTip {
                      visible: doneTodoMouse.containsMouse && !editing
                      text: root.todoRowTooltip()
                      fontFamily: root.contentFontFamily
                    }
                  }

                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    BorderSurface {
                      width: Style.space(16)
                      height: Style.space(16)
                      anchors.verticalCenter: parent.verticalCenter
                      radius: Math.max(2, Style.cornerRadius * 0.45)
                      color: Style.selectedFillFor(root.contentForeground, Color.accent)
                      borderSpec: Border.controlSpec(
                        "selected",
                        root.contentForeground,
                        Color.accent)

                      Text {
                        anchors.centerIn: parent
                        text: "\u2713"
                        textFormat: Text.PlainText
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }

                    Text {
                      id: doneTodoLabel
                      visible: !editing
                      width: parent.width - Style.space(24)
                      text: modelData.text
                      textFormat: Text.PlainText
                      color: Qt.darker(root.contentForeground, 1.6)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.strikeout: true
                      wrapMode: Text.WordWrap
                    }

                    TextField {
                      id: doneTodoEdit
                      visible: editing
                      width: parent.width - Style.space(24)
                      foreground: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      verticalPadding: Style.space(2)
                      horizontalPadding: Style.space(6)
                      onVisibleChanged: {
                        if (!visible) return
                        text = String(modelData.text || "")
                        Qt.callLater(function() {
                          doneTodoEdit.forceActiveFocus()
                          doneTodoEdit.selectAll()
                        })
                      }
                      onAccepted: root.commitTodoEdit(text)
                      onEditingFinished: {
                        if (root.isEditingTodo(root.journalTab, modelData.index))
                          root.commitTodoEdit(text)
                      }
                      Keys.onEscapePressed: function(event) {
                        root.cancelTodoEdit()
                        event.accepted = true
                      }
                    }
                  }
                }
              }
            }

          }
        }
      }
    }

  Process {
    id: unameProc
    command: ["uname", "-m"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.hostArch = String(text || "").trim()
        root.resolveJournalBin()
      }
    }
  }

  Process {
    id: binProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var found = String(text || "").trim()
        if (found === "") return
        root.resolvedJournalBin = found
        if (root.selectedKey !== "") root.loadJournal()
        root.loadMonthMarks()
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.resolvedJournalBin = ""
        root.journalError = "Journal backend missing — reinstall austraz.clock (bundled bin/) or set journalBin"
      }
    }
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyJournalLine(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.journalError === "")
        root.journalError = "Could not read journal (exit " + exitCode + ")"
      if (!statusProc.running && root.pendingStatusDate !== "")
        root.pumpStatus()
    }
  }

  Process {
    id: monthProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyMonthLine(text)
    }
    onExited: function() {
      if (root.pendingMonthMarks) {
        root.pendingMonthMarks = false
        root.loadMonthMarks()
      }
    }
  }

  Process {
    id: notesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyJournalLine(text)
    }
    onRunningChanged: {
      if (running) return
      if (root.pendingAdd !== "") {
        var text = root.pendingAdd
        root.pendingAdd = ""
        root.submitAdd(text)
        return
      }
      if (root.pendingDefer) {
        var job = root.pendingDefer
        root.pendingDefer = null
        root.deferTodo(job.heading, job.index)
        return
      }
      if (root.pendingEdit) {
        var edit = root.pendingEdit
        root.pendingEdit = null
        root.submitTodoEdit(edit.heading, edit.index, edit.text)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyJournalLine(text)
    }
  }
}
