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
  readonly property string todoHeading: String(setting("todoHeading", "Tasks") || "").trim()
  readonly property int notesH2Count: {
    var n = Number(setting("notesH2Count", 2))
    if (!isFinite(n) || n < 1) return 2
    return Math.floor(n)
  }
  property string hostArch: ""
  property string resolvedJournalBin: ""
  readonly property string journalBin: root.resolvedJournalBin

  property string journalNotes: ""
  property string journalDraft: ""
  property bool journalDirty: false
  property string journalSynced: ""
  property string journalTab: "notes"
  property string notesHeading: "Notes"
  property string linksHeading: "Links / captured ideas"
  property string morningHeading: "Morning review"
  property string nightlyHeading: "Nightly review"
  property string notesDraft: ""
  property string linksDraft: ""
  property string morningDraft: ""
  property string nightlyDraft: ""
  property string notesSynced: ""
  property string linksSynced: ""
  property string morningSynced: ""
  property string nightlySynced: ""
  property bool applyingJournal: false
  property string editorLoadedKey: ""
  readonly property bool tasksTab: journalTab === "tasks"
  readonly property bool reviewTab: journalTab === "morning" || journalTab === "nightly"
  readonly property var journalTabs: [
    { key: "notes", label: "Notes", tooltip: "Notes" },
    { key: "links", label: "Links", tooltip: "Links / captured ideas" },
    { key: "tasks", label: "Tasks", tooltip: "Tasks" },
    { key: "morning", label: "󰖨", tooltip: "Morning review" },
    { key: "nightly", label: "󰖔", tooltip: "Nightly review" }
  ]
  property bool journalExists: false
  property string journalError: ""
  property string journalUri: ""
  property var todos: []
  property string pendingAdd: ""
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
  readonly property int todoDotSize: Style.space(4)
  readonly property int dayNumberHeight: Style.space(18)
  readonly property int dayNumberTop: Style.space(6)

  function open() {
    refresh()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
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
    var cmd = [root.journalBin, "--vault", root.vaultPath]
    if (root.todoHeading !== "") {
      cmd.push("--heading")
      cmd.push(root.todoHeading)
    }
    return cmd
  }

  function journalCommand(args) {
    return root.journalPrefix().concat(args)
  }

  function monthJournalCommand(args) {
    var cmd = root.journalPrefix()
    if (root.notesH2Count > 0) {
      cmd.push("--notes-h2-count")
      cmd.push(String(root.notesH2Count))
    }
    return cmd.concat(args)
  }

  function lineIsMarkdownHeading(line) {
    return /^#{1,6}\s+\S/.test(String(line || "").trim())
  }

  function notesHaveBody(notes) {
    return String(notes || "").split("\n").some(function(line) {
      var t = String(line || "").trim()
      return t !== "" && !root.lineIsMarkdownHeading(t)
    })
  }

  function kindForHeading(title) {
    var t = String(title || "").trim().toLowerCase()
    if (t === "tasks" || t === "todos" || t === "tâches") return "tasks"
    if (t.indexOf("link") >= 0 || t.indexOf("captured") >= 0 || t.indexOf("idée") >= 0 || t.indexOf("idee") >= 0)
      return "links"
    if (t.indexOf("morning") >= 0 || t.indexOf("matinal") >= 0) return "morning"
    if (t.indexOf("night") >= 0 || t.indexOf("nightly") >= 0 || t.indexOf("nocturne") >= 0)
      return "nightly"
    if (t === "notes") return "notes"
    return ""
  }

  function headingForTab(tab) {
    if (tab === "links") return root.linksHeading
    if (tab === "morning") return root.morningHeading
    if (tab === "nightly") return root.nightlyHeading
    if (tab === "tasks") return root.todoHeading || "Tasks"
    return root.notesHeading
  }

  function draftForTab(tab) {
    if (tab === "links") return root.linksDraft
    if (tab === "morning") return root.morningDraft
    if (tab === "nightly") return root.nightlyDraft
    return root.notesDraft
  }

  function syncedForTab(tab) {
    if (tab === "links") return root.linksSynced
    if (tab === "morning") return root.morningSynced
    if (tab === "nightly") return root.nightlySynced
    return root.notesSynced
  }

  function setDraftForTab(tab, text) {
    if (tab === "links") root.linksDraft = text
    else if (tab === "morning") root.morningDraft = text
    else if (tab === "nightly") root.nightlyDraft = text
    else root.notesDraft = text
  }

  function setSyncedForTab(tab, text) {
    if (tab === "links") root.linksSynced = text
    else if (tab === "morning") root.morningSynced = text
    else if (tab === "nightly") root.nightlySynced = text
    else root.notesSynced = text
  }

  function placeholderForTab(tab) {
    if (tab === "links") return "Capture a link or idea…"
    if (tab === "morning") return "Morning review…"
    if (tab === "nightly") return "Nightly review…"
    return root.journalExists ? "Write a note…" : "No note yet — type to create it"
  }

  function splitLeadingCheckboxes(body) {
    var lines = String(body || "").split("\n")
    var todos = []
    var i = 0
    var re = /^(\s*)([-*+])\s+\[([ xX])\]\s+(.*)$/
    while (i < lines.length && String(lines[i]).trim() === "")
      i++
    while (i < lines.length) {
      var match = re.exec(lines[i])
      if (!match) break
      todos.push({
        index: todos.length,
        checked: match[3] !== " ",
        text: match[4],
        indent: match[1],
        bullet: match[2]
      })
      i++
    }
    return { todos: todos, rest: lines.slice(i).join("\n") }
  }

  function composeReviewBody(todos, rest) {
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
    if (tab === "morning" || tab === "nightly")
      return root.splitLeadingCheckboxes(root.draftForTab(tab)).rest
    return root.draftForTab(tab)
  }

  readonly property var visibleReviewTodos: {
    var body = ""
    if (root.journalTab === "morning") body = root.morningDraft
    else if (root.journalTab === "nightly") body = root.nightlyDraft
    return root.splitLeadingCheckboxes(body).todos
  }

  function setEditorFromTab(force) {
    if (!journalArea || root.journalTab === "tasks") return
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

  function applySections(list) {
    var keepTab = ""
    var keepBody = ""
    if (journalArea && journalArea.activeFocus && root.editorLoadedKey === root.selectedKey) {
      keepTab = root.journalTab
      keepBody = root.draftForTab(keepTab)
    }
    root.notesHeading = "Notes"
    root.linksHeading = "Links / captured ideas"
    root.morningHeading = "Morning review"
    root.nightlyHeading = "Nightly review"
    root.notesDraft = ""
    root.linksDraft = ""
    root.morningDraft = ""
    root.nightlyDraft = ""
    if (Array.isArray(list)) {
      for (var i = 0; i < list.length; i++) {
        var item = list[i]
        if (!item || typeof item !== "object") continue
        var kind = root.kindForHeading(item.heading)
        if (kind === "" || kind === "tasks") continue
        var body = typeof item.body === "string" ? item.body : ""
        if (kind === "links") {
          root.linksHeading = String(item.heading || root.linksHeading)
          root.linksDraft = body
        } else if (kind === "morning") {
          root.morningHeading = String(item.heading || root.morningHeading)
          root.morningDraft = body
        } else if (kind === "nightly") {
          root.nightlyHeading = String(item.heading || root.nightlyHeading)
          root.nightlyDraft = body
        } else {
          root.notesHeading = String(item.heading || root.notesHeading)
          root.notesDraft = body
        }
      }
    }
    if (keepTab !== "" && keepTab !== "tasks")
      root.setDraftForTab(keepTab, keepBody)
    root.notesSynced = root.notesDraft
    root.linksSynced = root.linksDraft
    root.morningSynced = root.morningDraft
    root.nightlySynced = root.nightlyDraft
    if (keepTab !== "") {
      root.setSyncedForTab(keepTab, keepBody)
      root.journalDraft = journalArea.text
      root.journalSynced = keepBody
    } else {
      root.journalDraft = root.editorTextForTab(root.journalTab)
      root.journalSynced = root.syncedForTab(root.journalTab)
    }
    root.setEditorFromTab(false)
  }

  function selectJournalTab(tab) {
    var next = String(tab || "")
    if (next === "" || next === root.journalTab) return
    if (root.journalDirty) root.saveJournalNow()
    root.journalTab = next
    root.applyingJournal = true
    root.journalDraft = root.editorTextForTab(next)
    root.journalSynced = root.syncedForTab(next)
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

  function dayHasNote(cell, marks) {
    if (!cell || !cell.key || !cell.inMonth) return false
    var table = marks || root.monthMarks
    var mark = table ? table[cell.key] : null
    return !!(mark && mark.hasNotes)
  }

  function saveJournalNow() {
    journalSaveTimer.stop()
    if (!root.journalDirty) return
    if (root.journalTab === "tasks") return
    if (root.journalBin === "" || root.vaultPath === "") return
    var heading = root.headingForTab(root.journalTab)
    var body = root.draftForTab(root.journalTab)
    root.journalDirty = false
    root.journalSynced = body
    root.setSyncedForTab(root.journalTab, body)
    notesProc.command = root.journalPrefix().concat([
      "--notes-heading", heading,
      "set-notes", "--date", root.selectedKey, "--text", body
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
    root.applySections(parsed.sections)
    root.journalNotes = typeof parsed.notes === "string" ? parsed.notes : ""
    if (!keepEditor)
      root.journalDirty = false
    root.applyingJournal = false
    var dateKey = parsed.date ? String(parsed.date) : root.selectedKey
    if (dateKey !== "") {
      var open = Number(parsed.openCount)
      var done = Number(parsed.doneCount)
      if (!isFinite(open)) open = nextTodos.filter(function(t) { return !t.checked }).length
      if (!isFinite(done)) done = nextTodos.filter(function(t) { return t.checked }).length
      var hasNotes = root.notesHaveBody(root.notesDraft) || root.notesHaveBody(root.linksDraft)
      root.patchMonthMark(dateKey, open, done, hasNotes)
    }
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
    if (trimmed === "" || root.journalBin === "" || root.vaultPath === "" || root.selectedKey === "")
      return
    actionProc.command = root.journalCommand(["add", "--date", root.selectedKey, "--text", trimmed])
    actionProc.running = true
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

  function toggleReviewTodo(index) {
    var n = Number(index)
    if (!isFinite(n) || n < 0) return
    var tab = root.journalTab
    if (tab !== "morning" && tab !== "nightly") return
    var split = root.splitLeadingCheckboxes(root.draftForTab(tab))
    if (n >= split.todos.length) return
    var rest = journalArea && !root.tasksTab ? journalArea.text : split.rest
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
    var next = root.composeReviewBody(todos, rest)
    root.setDraftForTab(tab, next)
    root.setSyncedForTab(tab, next)
    root.journalDraft = root.editorTextForTab(tab)
    root.journalSynced = next
    root.journalDirty = false
    journalSaveTimer.stop()
    if (root.journalBin === "" || root.vaultPath === "") return
    notesProc.command = root.journalPrefix().concat([
      "--notes-heading", root.headingForTab(tab),
      "set-notes", "--date", root.selectedKey, "--text", next
    ])
    notesProc.running = true
  }

  function onJournalEdited(text) {
    if (root.applyingJournal || root.journalTab === "tasks") return
    var tab = root.journalTab
    var next = text
    if (tab === "morning" || tab === "nightly")
      next = root.composeReviewBody(root.splitLeadingCheckboxes(root.draftForTab(tab)).todos, text)
    root.setDraftForTab(tab, next)
    root.journalDraft = text
    root.journalDirty = (next !== root.syncedForTab(tab))
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
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(calendarColumn.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife || journalArea.activeFocus || todoInput.activeFocus
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

      // Calendar stays a non-scrolling block so day cells receive clicks
      // the same way the native "W" toggle does. Only the journal below
      // uses the leftover height.
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
                text: "Today's journal"
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
                  text: "Memento Mori"
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

                  Text {
                    textFormat: Text.PlainText
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
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

                    Text {
                      textFormat: Text.PlainText
                      width: root.weekColumnWidth
                      height: root.cellHeight
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter
                      text: modelData.week
                      color: Qt.darker(root.contentForeground, 1.9)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
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
                                color: day && day.inMonth
                                  ? Style.selectedStateColor(root.contentForeground, Color.accent)
                                  : Qt.darker(root.contentForeground, 1.9)
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

            RowLayout {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.journalTabs

                Rectangle {
                  required property var modelData
                  readonly property bool selected: modelData && modelData.key === root.journalTab
                  Layout.preferredHeight: Style.space(28)
                  Layout.preferredWidth: tabLabel.implicitWidth + Style.space(16)
                  radius: Style.cornerRadius
                  color: selected || tabMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"
                  border.width: selected ? Style.spacing.hairline : 0
                  border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                  Text {
                    id: tabLabel
                    anchors.centerIn: parent
                    text: modelData ? modelData.label : ""
                    textFormat: Text.PlainText
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

              Item { Layout.fillWidth: true }

              Text {
                visible: root.journalDirty
                text: "Saving…"
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              PanelActionButton {
                iconText: "\u2197"
                tooltipText: "Open in Obsidian"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.openSelectedInObsidian()
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

            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.tasksTab

              Repeater {
                model: root.todos

                Rectangle {
                  required property var modelData
                  width: calendarColumn.width
                  implicitHeight: todoLabel.implicitHeight + Style.space(10)
                  radius: Style.cornerRadius
                  color: todoMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  MouseArea {
                    id: todoMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleTodo(modelData.line, modelData.text)
                  }

                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: (modelData.depth || 0) * Style.space(14)
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
                      width: parent.width - Style.space(24)
                        - (modelData.depth || 0) * Style.space(14)
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
                  }
                }
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                height: todoInput.implicitHeight

                TextField {
                  id: todoInput
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  placeholderText: "Add a todo…"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  onAccepted: root.addTodo()
                  Keys.onEscapePressed: root.close()
                }

                PanelActionButton {
                  iconText: "+"
                  tooltipText: "Add todo"
                  bordered: true
                  size: todoInput.implicitHeight
                  Layout.preferredWidth: size
                  Layout.preferredHeight: size
                  Layout.alignment: Qt.AlignVCenter
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.body
                  onClicked: root.addTodo()
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.reviewTab

              Repeater {
                model: root.visibleReviewTodos

                Rectangle {
                  required property var modelData
                  width: calendarColumn.width
                  implicitHeight: reviewTodoLabel.implicitHeight + Style.space(10)
                  radius: Style.cornerRadius
                  color: reviewTodoMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  MouseArea {
                    id: reviewTodoMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleReviewTodo(modelData.index)
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
                      id: reviewTodoLabel
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
                  }
                }
              }
            }

            Item {
              id: journalFrame
              width: parent.width
              height: Style.space(180)
              visible: !root.tasksTab

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
      if (!running && root.pendingAdd !== "") {
        var text = root.pendingAdd
        root.pendingAdd = ""
        root.submitAdd(text)
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
