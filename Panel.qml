import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.viganogabriele.fast-note-todo"
  ipcTarget: "io.github.viganogabriele.fast-note-todo"
  manageIpc: false

  property var anchorItem: null
  property var host: null
  property string noteText: ""
  property string savedText: ""
  property string savePath: ""
  property string savingText: ""
  property string lookupOutput: ""
  property string lookupError: ""
  property string storageStatus: "idle"
  property bool loaded: false
  property bool saveQueued: false
  property bool tempWriteFailed: false

  property string viewMode: "note"
  property bool showCompleted: false
  property var completedItems: []
  property string newTodoText: ""
  property string savedTodoJson: "{}"
  property string savingTodoJson: ""
  property string todoSavePath: ""
  property string todoLookupOutput: ""
  property string todoLookupError: ""
  property string todoStorageStatus: "idle"
  property bool todoLoaded: false
  property bool todoSaveQueued: false
  property bool todoTempWriteFailed: false

  // Drag-to-reorder state. uid identifies which row is airborne independent
  // of its live index (index keeps changing as todoModel.move() commits each
  // step), -1 means nothing is being dragged.
  property int nextTodoUid: 1
  property int draggingUid: -1
  property real dragOffsetY: 0
  property int dragStepsCommitted: 0

  // Inline text editing. -1 means no row is being edited. discardPendingEdit
  // is a one-shot flag: set right before clearing editingUid to make the
  // close discard instead of save (Escape); left false everywhere else.
  property int editingUid: -1
  property bool discardPendingEdit: false

  readonly property bool dirty: noteText !== savedText
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property color foreground: Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- sizing
  // Bigger and non-square on purpose (the old 217x217 box was cramped for
  // two whole views) and, in To-Do mode, adaptive to how many items exist:
  // it grows with the list up to a cap, then the inner list scrolls.
  readonly property int panelContentWidth: Style.space(300)
  readonly property int noteContentHeight: Style.space(340)
  readonly property int todoChrome: Style.space(100)
  readonly property int todoListCap: Style.space(400)
  readonly property int panelMaxHeight: Style.space(560)

  // Both views share one height: whichever naturally wants more room. A
  // panel that shrinks the moment you flip tabs feels broken, so switching
  // between Nota and To-Do never makes it smaller — only the To-Do list's
  // own item count can grow it further (up to the cap), never note the
  // other way around. The note grows the same way: vertically, with the
  // actual text, instead of ever changing width — a box that gets wider
  // while you type would jitter and need to re-center itself, which is a
  // worse feeling than a taller scratchpad that just keeps up with you.
  function fittedContentHeightFor() {
    var listHeight = root.showCompleted ? completedColumn.implicitHeight : todoColumn.implicitHeight
    var todoHeight = todoChrome + Math.min(listHeight, todoListCap)
    var noteHeight = Math.max(noteContentHeight, noteArea.implicitHeight + Style.space(20))
    return Math.max(noteHeight, todoHeight)
  }

  ListModel {
    id: todoModel
  }

  function todoModelSnapshot() {
    var out = []
    for (var i = 0; i < todoModel.count; i++) {
      var it = todoModel.get(i)
      out.push({ text: it.text, done: it.done === true })
    }
    return out
  }

  function currentTodoJson() {
    return JSON.stringify({ mode: viewMode, items: todoModelSnapshot(), completed: completedItems })
  }

  function isTodoDirty() {
    return currentTodoJson() !== savedTodoJson
  }

  // The keyring attribute stays "b.omanote" (the plugin's pre-fork id) on
  // purpose, independent of moduleName/ipcTarget above — changing it would
  // orphan whatever note is already stored under that key.
  function loadScript(field) {
    return "command -v secret-tool >/dev/null 2>&1 || { echo 'secret-tool not found' >&2; exit 127; }\n"
      + "secret-tool lookup omarchy-plugin b.omanote field " + field
  }

  function storeScript(field) {
    var label = field === "todos" ? "Omanote todos" : "Omanote note"
    return "path=$1\n"
      + "if ! command -v secret-tool >/dev/null 2>&1; then\n"
      + "  echo 'secret-tool not found' >&2\n"
      + "  rm -f -- \"$path\"\n"
      + "  exit 127\n"
      + "fi\n"
      + "secret-tool store --label='" + label + "' omarchy-plugin b.omanote field " + field + " < \"$path\"\n"
      + "status=$?\n"
      + "rm -f -- \"$path\"\n"
      + "exit \"$status\""
  }

  function clearScript(field) {
    return "command -v secret-tool >/dev/null 2>&1 || { echo 'secret-tool not found' >&2; exit 127; }\n"
      + "secret-tool clear omarchy-plugin b.omanote field " + field
  }

  function tempPath() {
    if (runtimeDir === "") return ""
    return runtimeDir + "/omanote-"
      + Date.now().toString(36)
      + "-"
      + Math.floor(Math.random() * 0x100000000).toString(36)
      + ".txt"
  }

  // Just moves focus — used when flipping Nota/To-Do tabs, where jumping
  // the cursor to the end of a long note on every click would feel like a
  // jarring scroll-jump instead of a tab switch.
  function focusEditor() {
    if (root.viewMode === "todo") {
      newTodoField.forceActiveFocus()
    } else {
      noteArea.forceActiveFocus()
    }
  }

  function open() {
    root.controller.show()
    if (!loaded && !lookupProc.running) loadNote()
    if (!todoLoaded && !todoLookupProc.running) loadTodos()
    if (todoLoaded) pruneOldCompleted()
    Qt.callLater(function() {
      focusEditor()
      if (root.viewMode === "note") noteArea.cursorPosition = noteArea.text.length
    })
  }

  function close() {
    root.closeEditIfAny()
    saveTimer.stop()
    if (dirty) saveNow()
    todoSaveTimer.stop()
    if (isTodoDirty()) saveTodosNow()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function updateText(value) {
    noteText = String(value || "")
    if (!loaded || storageStatus === "loading") return
    saveTimer.restart()
  }

  function loadNote() {
    lookupOutput = ""
    lookupError = ""
    storageStatus = "loading"
    lookupProc.command = ["bash", "-c", loadScript("note"), "omanote-load"]
    lookupProc.running = true
  }

  function applyLoadedText(exitCode) {
    var error = String(lookupError || "").trim()
    if (exitCode === 0 || error === "") {
      var text = exitCode === 0 ? String(lookupOutput || "") : ""
      noteText = text
      savedText = text
      loaded = true
      storageStatus = "ready"
      return
    }

    loaded = true
    storageStatus = "error"
  }

  function saveNow() {
    if (!loaded || storageStatus === "loading") return
    if (!dirty && storageStatus !== "error") return

    if (storeProc.running || clearProc.running) {
      saveQueued = true
      return
    }

    savingText = noteText
    storageStatus = "saving"

    if (savingText === "") {
      clearProc.command = ["bash", "-c", clearScript("note"), "omanote-clear"]
      clearProc.running = true
      return
    }

    var path = tempPath()
    if (path === "") {
      storageStatus = "error"
      return
    }

    // Secret-tool needs EOF for multiline stdin. The transient source file
    // lives only in the user's runtime tmpfs and is deleted by storeScript().
    savePath = path
    tempWriteFailed = false
    saveFile.setText(savingText)
    if (tempWriteFailed) {
      storageStatus = "error"
      return
    }

    storeProc.command = ["bash", "-c", storeScript("note"), "omanote-store", path]
    storeProc.running = true
  }

  function finishSave(exitCode) {
    savePath = ""

    if (exitCode === 0) {
      savedText = savingText
      storageStatus = noteText === savedText ? "ready" : "saving"
    } else {
      storageStatus = "error"
    }

    savingText = ""

    if (saveQueued || (storageStatus !== "error" && noteText !== savedText)) {
      saveQueued = false
      Qt.callLater(saveNow)
    }
  }

  function addTodoItem() {
    var text = String(newTodoText || "").trim()
    if (text === "") return
    todoModel.append({ uid: root.nextTodoUid++, text: text, done: false })
    newTodoText = ""
    newTodoField.text = ""
    newTodoField.forceActiveFocus()
    scheduleTodoSave()
  }

  function setTodoDone(index, done) {
    if (index < 0 || index >= todoModel.count) return
    todoModel.setProperty(index, "done", done)
    scheduleTodoSave()
  }

  function deleteTodoAt(index) {
    if (index < 0 || index >= todoModel.count) return
    if (root.editingUid === todoModel.get(index).uid) root.editingUid = -1
    todoModel.remove(index)
    scheduleTodoSave()
  }

  function setTodoText(index, text) {
    if (index < 0 || index >= todoModel.count) return
    var trimmed = String(text || "").trim()
    if (trimmed === "") return
    todoModel.setProperty(index, "text", trimmed)
    scheduleTodoSave()
  }

  // Closing an edit (for any reason — Enter, clicking a different item,
  // clicking anything else in the panel) always goes through here so the
  // in-flight text commits exactly once, in editField's onVisibleChanged.
  function beginEditTodo(uid) {
    root.editingUid = uid
  }

  function closeEditIfAny() {
    if (root.editingUid !== -1) root.editingUid = -1
  }

  function moveTodoItem(index, target) {
    if (index < 0 || index >= todoModel.count) return
    if (target < 0 || target >= todoModel.count) return
    if (index === target) return
    todoModel.move(index, target, 1)
  }

  // Completed items age out after completedRetentionMs regardless of count —
  // a stale 20th entry sitting for weeks was more surprising than useful.
  readonly property int completedRetentionMs: 2 * 24 * 60 * 60 * 1000

  function pruneOldCompleted() {
    var cutoff = Date.now() - completedRetentionMs
    var kept = completedItems.filter(function(item) { return item.completedAt >= cutoff })
    if (kept.length !== completedItems.length) {
      completedItems = kept
      scheduleTodoSave()
    }
  }

  function removeTodoAt(index) {
    if (index < 0 || index >= todoModel.count) return
    var removedText = todoModel.get(index).text
    todoModel.remove(index)
    if (removedText) {
      completedItems = [{ text: removedText, completedAt: Date.now() }].concat(completedItems).slice(0, 50)
    }
    scheduleTodoSave()
  }

  function restoreCompletedItem(index) {
    if (index < 0 || index >= completedItems.length) return
    var completed = completedItems.slice()
    var entry = completed.splice(index, 1)[0]
    completedItems = completed
    todoModel.append({ uid: root.nextTodoUid++, text: entry.text, done: false })
    scheduleTodoSave()
  }

  function scheduleTodoSave() {
    if (!todoLoaded || todoStorageStatus === "loading") return
    todoSaveTimer.restart()
  }

  function loadTodos() {
    todoLookupOutput = ""
    todoLookupError = ""
    todoStorageStatus = "loading"
    todoLookupProc.command = ["bash", "-c", loadScript("todos"), "omanote-load-todos"]
    todoLookupProc.running = true
  }

  function applyLoadedTodos(exitCode) {
    var error = String(todoLookupError || "").trim()
    if (exitCode === 0 || error === "") {
      var raw = exitCode === 0 ? String(todoLookupOutput || "") : ""
      var parsedItems = []
      var parsedCompleted = []
      var parsedMode = root.viewMode
      if (raw !== "") {
        try {
          var data = JSON.parse(raw)
          if (Array.isArray(data)) {
            parsedItems = data
              .filter(function(item) { return item && typeof item.text === "string" })
              .map(function(item) { return { text: item.text, done: item.done === true } })
          } else if (data && typeof data === "object") {
            if (Array.isArray(data.items)) {
              parsedItems = data.items
                .filter(function(item) { return item && typeof item.text === "string" })
                .map(function(item) { return { text: item.text, done: item.done === true } })
            }
            if (Array.isArray(data.completed)) {
              // Older saves stored plain strings with no timestamp — treat
              // those as just-completed rather than dropping them outright.
              parsedCompleted = data.completed
                .map(function(entry) {
                  if (typeof entry === "string") return { text: entry, completedAt: Date.now() }
                  if (entry && typeof entry.text === "string") {
                    return { text: entry.text, completedAt: Number(entry.completedAt) || Date.now() }
                  }
                  return null
                })
                .filter(Boolean)
            }
            if (data.mode === "note" || data.mode === "todo") {
              parsedMode = data.mode
            }
          }
        } catch (e) {
          parsedItems = []
          parsedCompleted = []
        }
      }
      var cutoff = Date.now() - root.completedRetentionMs
      var beforePruneCount = parsedCompleted.length
      parsedCompleted = parsedCompleted.filter(function(entry) { return entry.completedAt >= cutoff })
      var prunedOnLoad = parsedCompleted.length !== beforePruneCount
      todoModel.clear()
      for (var i = 0; i < parsedItems.length; i++) {
        todoModel.append({ uid: root.nextTodoUid++, text: parsedItems[i].text, done: parsedItems[i].done === true })
      }
      completedItems = parsedCompleted
      root.viewMode = parsedMode
      todoLoaded = true
      todoStorageStatus = "ready"
      if (prunedOnLoad) {
        // Force a save even though the in-memory state matches what we just
        // loaded — the on-disk copy still has the expired entries in it.
        savedTodoJson = ""
        scheduleTodoSave()
      } else {
        savedTodoJson = JSON.stringify({ mode: parsedMode, items: parsedItems, completed: parsedCompleted })
      }
      return
    }

    todoLoaded = true
    todoStorageStatus = "error"
  }

  function saveTodosNow() {
    if (!todoLoaded || todoStorageStatus === "loading") return
    if (!isTodoDirty() && todoStorageStatus !== "error") return

    if (todoStoreProc.running || todoClearProc.running) {
      todoSaveQueued = true
      return
    }

    savingTodoJson = currentTodoJson()
    todoStorageStatus = "saving"

    if (todoModel.count === 0 && completedItems.length === 0) {
      todoClearProc.command = ["bash", "-c", clearScript("todos"), "omanote-clear-todos"]
      todoClearProc.running = true
      return
    }

    var path = tempPath()
    if (path === "") {
      todoStorageStatus = "error"
      return
    }

    todoSavePath = path
    todoTempWriteFailed = false
    todoSaveFile.setText(savingTodoJson)
    if (todoTempWriteFailed) {
      todoStorageStatus = "error"
      return
    }

    todoStoreProc.command = ["bash", "-c", storeScript("todos"), "omanote-store-todos", path]
    todoStoreProc.running = true
  }

  function finishTodoSave(exitCode) {
    todoSavePath = ""

    if (exitCode === 0) {
      savedTodoJson = savingTodoJson
      todoStorageStatus = currentTodoJson() === savedTodoJson ? "ready" : "saving"
    } else {
      todoStorageStatus = "error"
    }

    savingTodoJson = ""

    if (todoSaveQueued || (todoStorageStatus !== "error" && isTodoDirty())) {
      todoSaveQueued = false
      Qt.callLater(saveTodosNow)
    }
  }

  onViewModeChanged: scheduleTodoSave()

  onOpenedChanged: {
    if (opened) {
      if (!loaded && !lookupProc.running) loadNote()
      if (!todoLoaded && !todoLookupProc.running) loadTodos()
      Qt.callLater(function() {
        focusEditor()
        if (root.viewMode === "note") noteArea.cursorPosition = noteArea.text.length
      })
    } else {
      // Covers every way the panel can close, including a click outside it
      // that the base Panel dismisses on its own — commit any in-flight
      // edit before it's gone, so typed-but-unconfirmed text isn't lost.
      root.closeEditIfAny()
      if (dirty) {
        saveTimer.stop()
        saveNow()
      }
      if (isTodoDirty()) {
        todoSaveTimer.stop()
        saveTodosNow()
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
  }

  Timer {
    id: saveTimer
    interval: 850
    repeat: false
    onTriggered: root.saveNow()
  }

  Timer {
    id: todoSaveTimer
    interval: 850
    repeat: false
    onTriggered: root.saveTodosNow()
  }

  FileView {
    id: saveFile
    path: root.savePath
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onSaveFailed: root.tempWriteFailed = true
  }

  FileView {
    id: todoSaveFile
    path: root.todoSavePath
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onSaveFailed: root.todoTempWriteFailed = true
  }

  Process {
    id: lookupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lookupOutput = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lookupError = text
    }
    onExited: function(exitCode) { root.applyLoadedText(exitCode) }
  }

  Process {
    id: storeProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.finishSave(exitCode) }
  }

  Process {
    id: clearProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.finishSave(exitCode) }
  }

  Process {
    id: todoLookupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.todoLookupOutput = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.todoLookupError = text
    }
    onExited: function(exitCode) { root.applyLoadedTodos(exitCode) }
  }

  Process {
    id: todoStoreProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.finishTodoSave(exitCode) }
  }

  Process {
    id: todoClearProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.finishTodoSave(exitCode) }
  }

  KeyboardPanel {
    id: notePanel
    anchorItem: root.anchorItem
    owner: root.host || root
    bar: root.bar
    open: root.opened
    focusTarget: root.viewMode === "todo" ? newTodoField : noteArea
    contentWidth: notePanel.fittedContentWidth(root.panelContentWidth)
    contentHeight: notePanel.fittedContentHeight(root.fittedContentHeightFor(), root.panelMaxHeight)

    Item {
      anchors.fill: parent
      focus: true

      // Single Escape owner for the whole panel — fires before whichever
      // field has focus, so Escape reliably closes the panel regardless of
      // where the cursor happens to be. Previously each field (note, add
      // field, inline edit) handled Escape on its own; if focus had drifted
      // off all three (or landed in the inline editor, which used Escape to
      // discard instead), Escape silently did nothing.
      Keys.priority: Keys.BeforeItem
      Keys.onEscapePressed: function(event) {
        if (root.editingUid !== -1) {
          root.discardPendingEdit = true
          root.editingUid = -1
        } else {
          root.close()
        }
        event.accepted = true
      }

      // Catches clicks that land on empty panel background (not on any row,
      // button, or field) so an open inline edit still closes there too.
      MouseArea {
        anchors.fill: parent
        enabled: root.editingUid !== -1
        onClicked: root.closeEditIfAny()
      }

      // ---------- Nota / To-Do switch ----------
      // Same equal-width segmented pattern as the Agents panel's Claude/Codex
      // provider switch: full-width cells, standard control padding.
      Row {
        id: modeSwitch
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.spacing.md

        readonly property real cellWidth: (width - spacing) / 2

        Button {
          width: modeSwitch.cellWidth
          text: "Note"
          selected: root.viewMode === "note"
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: {
            root.closeEditIfAny()
            root.viewMode = "note"
            Qt.callLater(root.focusEditor)
          }
        }

        Button {
          width: modeSwitch.cellWidth
          text: "To-Do"
          selected: root.viewMode === "todo"
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: {
            root.closeEditIfAny()
            root.viewMode = "todo"
            Qt.callLater(root.focusEditor)
          }
        }
      }

      PanelSeparator {
        id: headerSeparator
        anchors.top: modeSwitch.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        foreground: root.foreground
      }

      Item {
        id: contentArea
        anchors.top: headerSeparator.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        QQC.ScrollView {
          id: editorScroll
          anchors.fill: parent
          visible: root.viewMode === "note"
          clip: true
          contentWidth: availableWidth
          contentHeight: Math.max(availableHeight, noteArea.implicitHeight)
          QQC.ScrollBar.vertical: QQC.ScrollBar {
            policy: QQC.ScrollBar.AlwaysOff
          }
          QQC.ScrollBar.horizontal: QQC.ScrollBar {
            policy: QQC.ScrollBar.AlwaysOff
          }

          background: null

          QQC.TextArea {
            id: noteArea
            width: editorScroll.availableWidth
            height: Math.max(editorScroll.availableHeight, implicitHeight)
            text: root.noteText
            placeholderText: ""
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            persistentSelection: true
            color: root.foreground
            selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            leftPadding: 0
            rightPadding: 0
            topPadding: 0
            bottomPadding: 0
            background: null
            enabled: root.storageStatus !== "loading"
            onTextChanged: if (text !== root.noteText) root.updateText(text)
          }
        }

        Item {
          id: todoView
          anchors.fill: parent
          visible: root.viewMode === "todo"

          Row {
            id: addRow
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.spacing.sm
            visible: !root.showCompleted

            TextField {
              id: newTodoField
              width: parent.width - addButton.width - historyButton.width - addRow.spacing * 2
              placeholderText: "New item…"
              text: root.newTodoText
              foreground: root.foreground
              enabled: root.todoStorageStatus !== "loading"
              onTextChanged: if (text !== root.newTodoText) root.newTodoText = text
              onAccepted: root.addTodoItem()
              onActiveFocusChanged: if (activeFocus) root.closeEditIfAny()
            }

            PanelActionButton {
              id: addButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "+"
              tooltipText: "Add"
              fontSize: Style.font.body
              foreground: root.foreground
              onClicked: {
                root.closeEditIfAny()
                root.addTodoItem()
              }
            }

            PanelActionButton {
              id: historyButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: ""
              tooltipText: "Recently completed"
              fontSize: Style.font.body
              foreground: root.foreground
              onClicked: {
                root.closeEditIfAny()
                root.showCompleted = true
              }
            }
          }

          PanelActionButton {
            id: backButton
            anchors.top: parent.top
            anchors.right: parent.right
            visible: root.showCompleted
            iconText: ""
            tooltipText: "Back to list"
            fontSize: Style.font.body
            foreground: root.foreground
            onClicked: root.showCompleted = false
          }

          Item {
            id: activeTodoArea
            anchors.top: addRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: !root.showCompleted

            QQC.ScrollView {
              id: todoScroll
              anchors.top: parent.top
              anchors.topMargin: Style.spacing.sm
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              clip: true
              contentWidth: availableWidth
              QQC.ScrollBar.vertical: QQC.ScrollBar {
                policy: QQC.ScrollBar.AsNeeded
              }
              QQC.ScrollBar.horizontal: QQC.ScrollBar {
                policy: QQC.ScrollBar.AlwaysOff
              }

              background: null

              // Taller than its rows whenever the list is short, so the
              // blank space below the cards — still inside the widget's
              // box, just below the scrollable viewport's own content —
              // is real clickable background instead of dead space the
              // Flickable swallows before it ever reaches anything behind it.
              Item {
                id: todoListWrapper
                width: todoScroll.availableWidth
                height: Math.max(todoColumn.implicitHeight, todoScroll.height)

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.closeEditIfAny()
                }

                Column {
                  id: todoColumn
                  anchors.top: parent.top
                  anchors.left: parent.left
                  anchors.right: parent.right
                  spacing: Style.spacing.sm

                  Repeater {
                    model: todoModel

                  delegate: Item {
                    id: todoRow
                    required property int uid
                    required property string text
                    required property bool done
                    required property int index

                    readonly property bool isDone: done === true
                    readonly property bool isDragging: root.draggingUid === todoRow.uid
                    readonly property bool isEditing: root.editingUid === todoRow.uid

                    width: parent.width
                    height: (isDone && !isDragging) ? 0 : rowCard.implicitHeight
                    opacity: (isDone && !isDragging) ? 0 : 1
                    clip: !isDragging
                    z: isDragging ? 1000 : 0

                    transform: Translate {
                      y: todoRow.isDragging ? root.dragOffsetY : 0
                    }

                    Behavior on height {
                      enabled: !todoRow.isDragging
                      NumberAnimation { duration: 220; easing.type: Easing.InOutQuad }
                    }
                    Behavior on opacity { NumberAnimation { duration: 220 } }

                    Timer {
                      interval: 230
                      running: todoRow.isDone && !todoRow.isDragging
                      onTriggered: root.removeTodoAt(todoRow.index)
                    }

                    Rectangle {
                      id: rowCard
                      width: parent.width
                      implicitHeight: rowContent.implicitHeight + Style.spacing.md * 2
                      height: implicitHeight
                      radius: Style.space(6)
                      color: (rowMouse.containsMouse || todoRow.isDragging) && !todoRow.isDone
                        ? Style.hoverFillFor(root.foreground, Color.accent)
                        : "transparent"
                      border.width: todoRow.isDragging ? 1 : 0
                      border.color: Color.accent

                      Behavior on color { ColorAnimation { duration: 100 } }

                      MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        // Reached for any click that isn't on the text field
                        // itself (which has its own MouseArea on top) — the
                        // checkbox/delete/drag zones fall through to here too
                        // while they're disabled during this row's own edit.
                        onClicked: root.closeEditIfAny()
                      }

                      Row {
                        id: rowContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.spacing.sm
                        anchors.rightMargin: Style.spacing.sm
                        spacing: Style.spacing.md

                        BorderSurface {
                          id: checkbox
                          width: Style.space(16)
                          height: Style.space(16)
                          radius: Math.max(2, Style.cornerRadius / 2)
                          anchors.verticalCenter: parent.verticalCenter
                          color: todoRow.isDone ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
                          borderSpec: todoRow.isDone
                            ? Border.controlSpec("selected", root.foreground, Color.accent)
                            : Border.controlSpec("normal", root.foreground, Color.accent)

                          Behavior on color { ColorAnimation { duration: 150 } }

                          Text {
                            anchors.centerIn: parent
                            text: "✓"
                            color: Style.selectedStateColor(root.foreground, Color.accent)
                            font.family: root.fontFamily
                            font.pixelSize: Math.round(checkbox.height * 0.8)
                            font.bold: true
                            scale: todoRow.isDone ? 1 : 0.4
                            opacity: todoRow.isDone ? 1 : 0

                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                          }

                          MouseArea {
                            anchors.fill: parent
                            anchors.margins: -Style.spacing.xxs
                            enabled: !todoRow.isDone && !todoRow.isEditing
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                              root.closeEditIfAny()
                              root.setTodoDone(todoRow.index, true)
                            }
                          }
                        }

                        Item {
                          id: textSlot
                          anchors.verticalCenter: parent.verticalCenter
                          width: rowContent.width - checkbox.width - deleteButton.width - dragHandle.width - rowContent.spacing * 3
                          height: Math.max(displayText.implicitHeight, editField.implicitHeight)
                          clip: true

                          Text {
                            id: displayText
                            visible: !todoRow.isEditing
                            anchors.verticalCenter: parent.verticalCenter
                            width: textSlot.width
                            text: todoRow.text
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.Wrap

                            MouseArea {
                              anchors.fill: parent
                              enabled: !todoRow.isDone
                              cursorShape: Qt.IBeamCursor
                              onClicked: root.beginEditTodo(todoRow.uid)
                            }
                          }

                          TextField {
                            id: editField
                            // Whatever made this field stop being visible — Enter,
                            // another item taking over the edit slot, a click
                            // anywhere else in the panel, or Escape via the
                            // panel-wide key catcher below — lands here exactly
                            // once and commits, unless root.discardPendingEdit
                            // was set first (Escape discards instead of saving).
                            visible: todoRow.isEditing
                            anchors.verticalCenter: parent.verticalCenter
                            width: textSlot.width
                            text: todoRow.text
                            foreground: root.foreground
                            font.pixelSize: Style.font.bodySmall

                            onVisibleChanged: {
                              if (visible) {
                                forceActiveFocus()
                                selectAll()
                              } else {
                                if (!root.discardPendingEdit) root.setTodoText(todoRow.index, text)
                                root.discardPendingEdit = false
                              }
                            }
                            onAccepted: root.editingUid = -1
                          }
                        }

                        PanelActionButton {
                          id: deleteButton
                          anchors.verticalCenter: parent.verticalCenter
                          iconText: "✕"
                          tooltipText: "Delete"
                          fontSize: Style.font.body
                          foreground: root.foreground
                          hoverColor: root.bar ? root.bar.urgent : Color.urgent
                          onClicked: {
                            root.closeEditIfAny()
                            root.deleteTodoAt(todoRow.index)
                          }
                        }

                        Item {
                          id: dragHandle
                          width: Style.space(20)
                          height: Style.space(20)
                          anchors.verticalCenter: parent.verticalCenter

                          Text {
                            anchors.centerIn: parent
                            // The braille glyph's ink sits noticeably above the
                            // true center of its own em-box in this font; nudge
                            // it down to match the checkbox/delete icon's line.
                            anchors.verticalCenterOffset: Style.space(2)
                            text: "⠿"
                            color: todoRow.isDragging ? Color.accent : Qt.darker(root.foreground, 1.4)
                            font.pixelSize: Style.font.body
                            font.family: root.fontFamily
                          }

                          MouseArea {
                            id: dragMouse
                            anchors.fill: parent
                            enabled: !todoRow.isDone && !todoRow.isEditing
                            cursorShape: Qt.SizeVerCursor
                            preventStealing: true

                            property real pressGlobalY: 0

                            onPressed: function(mouse) {
                              root.closeEditIfAny()
                              pressGlobalY = mapToItem(todoColumn, 0, mouse.y).y
                              root.draggingUid = todoRow.uid
                              root.dragOffsetY = 0
                              root.dragStepsCommitted = 0
                            }

                            onPositionChanged: function(mouse) {
                              if (root.draggingUid !== todoRow.uid) return
                              var globalY = mapToItem(todoColumn, 0, mouse.y).y
                              var totalDelta = globalY - pressGlobalY
                              var rowStep = rowCard.height + todoColumn.spacing
                              if (rowStep <= 0) return
                              var desiredSteps = Math.round(totalDelta / rowStep)
                              var guard = 0
                              while (desiredSteps !== root.dragStepsCommitted && guard < 50) {
                                var dir = desiredSteps > root.dragStepsCommitted ? 1 : -1
                                var newIndex = todoRow.index + dir
                                if (newIndex < 0 || newIndex >= todoModel.count) break
                                root.moveTodoItem(todoRow.index, newIndex)
                                root.dragStepsCommitted += dir
                                guard++
                              }
                              root.dragOffsetY = totalDelta - root.dragStepsCommitted * rowStep
                            }

                            function endDrag() {
                              root.draggingUid = -1
                              root.dragOffsetY = 0
                              root.dragStepsCommitted = 0
                              root.scheduleTodoSave()
                            }

                            onReleased: endDrag()
                            onCanceled: endDrag()
                          }
                        }
                      }
                    }
                  }
                }

                Text {
                  visible: todoModel.count === 0
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  topPadding: Style.spacing.xxl
                  text: "No items"
                  color: Qt.darker(root.foreground, 1.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
          }

          Item {
            id: completedArea
            anchors.top: backButton.bottom
            anchors.topMargin: Style.spacing.sm
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: root.showCompleted

            QQC.ScrollView {
              anchors.fill: parent
              clip: true
              contentWidth: availableWidth
              QQC.ScrollBar.vertical: QQC.ScrollBar {
                policy: QQC.ScrollBar.AsNeeded
              }
              QQC.ScrollBar.horizontal: QQC.ScrollBar {
                policy: QQC.ScrollBar.AlwaysOff
              }

              background: null

              Column {
                id: completedColumn
                width: parent.width
                spacing: Style.spacing.sm

                Repeater {
                  model: root.completedItems

                  delegate: Item {
                    id: completedRow
                    required property var modelData
                    required property int index
                    width: parent.width
                    height: completedCard.implicitHeight

                    Rectangle {
                      id: completedCard
                      width: parent.width
                      implicitHeight: completedRowContent.implicitHeight + Style.spacing.md * 2
                      height: implicitHeight
                      radius: Style.space(6)
                      color: completedMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                      Behavior on color { ColorAnimation { duration: 100 } }

                      MouseArea {
                        id: completedMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                      }

                      Row {
                        id: completedRowContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.spacing.sm
                        anchors.rightMargin: Style.spacing.sm
                        spacing: Style.spacing.md

                        PanelActionButton {
                          id: restoreButton
                          anchors.verticalCenter: parent.verticalCenter
                          iconText: "↺"
                          tooltipText: "Restore"
                          fontSize: Style.font.bodySmall
                          foreground: root.foreground
                          onClicked: root.restoreCompletedItem(completedRow.index)
                        }

                        Text {
                          text: completedRow.modelData.text
                          color: Qt.darker(root.foreground, 1.4)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.strikeout: true
                          wrapMode: Text.Wrap
                          anchors.verticalCenter: parent.verticalCenter
                          width: completedRowContent.width - restoreButton.width - completedRowContent.spacing
                        }
                      }
                    }
                  }
                }

                Text {
                  visible: root.completedItems.length === 0
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  topPadding: Style.spacing.xxl
                  text: "No recently completed items"
                  color: Qt.darker(root.foreground, 1.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
        }
      }
    }
  }
}
