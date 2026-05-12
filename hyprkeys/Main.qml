import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property bool parserStarted: false

  Component.onDestruction: {
    cleanupProcess();
  }

  function cleanupProcess() {
    if (hyprBindsProcess.running) hyprBindsProcess.running = false;
  }

  // Modmask conversion table (Bitwise flags)
  // 1=Shift, 2=Ctrl, 4=Alt, 8=Super (Mod4), 16=Mod1, 32=Mod2, 64=Mod3
  // Hyprland typically uses: 1=Shift, 2=Ctrl, 4=Alt, 8=Super
  function maskToMods(mask) {
    var mods = [];
    if (mask & 1) mods.push("Shift");
    if (mask & 2) mods.push("Ctrl");
    if (mask & 4) mods.push("Alt");
    if (mask & 8) mods.push("Super");
    if (mask & 16) mods.push("Mod1");
    if (mask & 32) mods.push("Mod2");
    if (mask & 64) mods.push("Mod3");
    return mods;
  }

  function formatKey(key) {
    var keyMap = {
      "a": "A", "b": "B", "c": "C", "d": "D", "e": "E", "f": "F", "g": "G", "h": "H",
      "i": "I", "j": "J", "k": "K", "l": "L", "m": "M", "n": "N", "o": "O", "p": "P",
      "q": "Q", "r": "R", "s": "S", "t": "T", "u": "U", "v": "V", "w": "W", "x": "X",
      "y": "Y", "z": "Z",
      "0": "0", "1": "1", "2": "2", "3": "3", "4": "4", "5": "5", "6": "6", "7": "7", "8": "8", "9": "9",
      "KP_0": "Num 0", "KP_1": "Num 1", "KP_2": "Num 2", "KP_3": "Num 3", "KP_4": "Num 4",
      "KP_5": "Num 5", "KP_6": "Num 6", "KP_7": "Num 7", "KP_8": "Num 8", "KP_9": "Num 9",
      "KP_DECIMAL": ".", "KP_DIVIDE": "/", "KP_MULTIPLY": "*", "KP_SUBTRACT": "-", "KP_ADD": "+",
      "KP_ENTER": "Enter", "KP_EQUAL": "=",
      "F1": "F1", "F2": "F2", "F3": "F3", "F4": "F4", "F5": "F5", "F6": "F6", "F7": "F7",
      "F8": "F8", "F9": "F9", "F10": "F10", "F11": "F11", "F12": "F12",
      "UP": "Up", "DOWN": "Down", "LEFT": "Left", "RIGHT": "Right",
      "SPACE": "Space", "ENTER": "Enter", "ESC": "Esc", "TAB": "Tab", "BACKSPACE": "Backspace",
      "DELETE": "Del", "INSERT": "Ins", "HOME": "Home", "END": "End", "PAGE_UP": "PgUp", "PAGE_DOWN": "PgDn",
      "CAPS_LOCK": "Caps", "NUM_LOCK": "Num", "SCROLL_LOCK": "Scroll",
      "XF86AUDIORAISEVOLUME": "Vol Up", "XF86AUDIOLOWERVOLUME": "Vol Down", "XF86AUDIOMUTE": "Mute",
      "XF86AUDIOMICMUTE": "Mic Mute", "XF86AUDIOPLAY": "Play", "XF86AUDIOPAUSE": "Pause",
      "XF86AUDIONEXT": "Next", "XF86AUDIOPREV": "Prev", "XF86AUDIOSTOP": "Stop",
      "XF86MONBRIGHTNESSUP": "Bright Up", "XF86MONBRIGHTNESSDOWN": "Bright Down",
      "PRINT": "PrtSc", "PAUSE": "Pause"
    };
    return keyMap[key] || key.toUpperCase();
  }

  function runParser() {
    if (hyprBindsProcess.running) return;

    // Clear previous data
    if (pluginApi) {
      pluginApi.pluginSettings.cheatsheetData = [];
    }

    hyprBindsProcess.command = ["hyprctl", "binds"];
    hyprBindsProcess.running = true;
  }

  Process {
    id: hyprBindsProcess
    running: false

    stdout: SplitParser {
      onRead: data => {
        // Accumulate output
        if (!root.fullOutput) root.fullOutput = "";
        root.fullOutput += data;
      }
    }

    onExited: (exitCode, exitStatus) => {
      if (exitCode !== 0) {
        console.error("Failed to run hyprctl binds");
        return;
      }

      var output = root.fullOutput || "";
      root.fullOutput = ""; // Reset

      var lines = output.split('\n');
      var categories = [];
      var currentCategory = null;
      var currentBlock = {}; // Temporary storage for a bind block

      // State machine to parse the text output
      // Format:
      // bindd
      //     modmask: 64
      //     submap: 
      //     key: A
      //     ...
      //     description: ...

      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        
        if (line === "") continue;

        // Check for new bind block start (usually starts with "bind" or "bindl" or "bindm")
        if (line.startsWith("bind")) {
          // Save previous block if exists
          if (Object.keys(currentBlock).length > 0) {
            addToCategory(currentBlock, categories);
          }
          currentBlock = {};
          continue;
        }

        // Parse key-value pairs
        var colonIndex = line.indexOf(':');
        if (colonIndex > 0) {
          var key = line.substring(0, colonIndex).trim();
          var value = line.substring(colonIndex + 1).trim();
          currentBlock[key] = value;
        }
      }

      // Don't forget the last block
      if (Object.keys(currentBlock).length > 0) {
        addToCategory(currentBlock, categories);
      }

      saveToDb(categories);
    }
  }

  function addToCategory(block, categories) {
    var submap = block["submap"] || "Global";
    var key = block["key"] || "Unknown";
    var modmask = parseInt(block["modmask"]) || 0;
    var description = block["description"] || "No description";
    var dispatcher = block["dispatcher"] || "";
    var arg = block["arg"] || "";

    // Skip internal/empty binds
    if (key === "catchall" || description === "" && dispatcher === "__lua" && arg === "5") {
       // Sometimes __lua 5 is a placeholder, skip if no desc
       if (description === "No description") return;
    }

    // Find or create category
    var category = null;
    for (var i = 0; i < categories.length; i++) {
      if (categories[i].title === submap) {
        category = categories[i];
        break;
      }
    }

    if (!category) {
      category = { "title": submap, "binds": [] };
      categories.push(category);
    }

    var mods = maskToMods(modmask);
    var formattedKey = formatKey(key);
    var fullKeyStr = mods.length > 0 ? mods.join(" + ") + " + " + formattedKey : formattedKey;

    // Clean up description if it has extra info
    if (description === "No description" && dispatcher && dispatcher !== "") {
       // Try to infer from dispatcher if possible, or leave as is
       // description = dispatcher + " " + arg; // Optional: show raw dispatcher
    }

    category.binds.push({
      "keys": fullKeyStr,
      "desc": description
    });
  }

  function saveToDb(data) {
    if (pluginApi) {
      pluginApi.pluginSettings.cheatsheetData = data;
      pluginApi.pluginSettings.detectedCompositor = "Hyprland";
      pluginApi.saveSettings();
    }
  }

  IpcHandler {
    target: "plugin:hyprkeys"

    function toggle() {
      if (root.pluginApi) {
        root.pluginApi.withCurrentScreen(screen => {
          root.pluginApi.togglePanel(screen);
        });
      }
    }
  }
}
