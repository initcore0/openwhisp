# Plugins

Optional surfaces layered on top of OpenWhisp. A plugin contributes its own
configuration in Settings and — if it declares them — a menu-bar shortcut and
spoken commands that route mid-dictation. Some contribute a window; **script
plugins** just run a declared pipeline over your text.

Two provenances, both **off until you turn one on**:

- **Built in** — compiled into the app. The meme generator is the first: dictate
  a description, and it picks a template, writes the captions, renders them
  locally, and lets you edit, export, or share.
- **Installed** — a folder you drop into the plugins directory. Runs as a
  [script plugin](#script-plugins), with no rebuild and no relaunch.

- [Architecture](#architecture)
- [Manifest schema](#manifest-schema)
- [Script plugins](#script-plugins)
- [Writing an in-repo plugin](#writing-an-in-repo-plugin)
- [Security and trust](#security-and-trust)
- [Path to hot-swappable](#path-to-hot-swappable)
- [Build flags and testing](#build-flags-and-testing)

---

## Architecture

Two layers, split on the line the codebase already draws: pure rules in
`OpenWhispCore` (covered by `swift test`), IO and AppKit in the app.

### Core — `OpenWhisp/Services/`, all tested

| Type | Responsibility |
|---|---|
| `PluginManifest` | The host/plugin contract. Id, name, version, symbol, entry kind, and the declared capabilities below. |
| `PluginDiscovery` | Merges an **ordered list of providers** into the plugin list. Earlier providers win id collisions. |
| `PluginEnablement` | The enabled set — **default-off**, with pruning of ids that no longer exist. |
| `PluginRegistry` | The compile-time list of in-repo plugins. |
| `PluginKeyEquivalent` | Which plugin gets which ⌘-shortcut, and who is refused. |
| `PluginVoiceCommandRouter` | Which plugin (if any) claims a spoken refine instruction. |
| `PluginInvocationContext` | What a plugin actually receives when invoked, including declared capabilities. |
| `PluginScriptPlan` | The **script tier's whole decision layer**: step validation, the error taxonomy, consent derivation, prompt expansion. Alongside it, `PluginScriptPath` (a script must stay inside its own plugin folder) and `PluginScriptConsent` (the separate permission to execute code). |

### App

| Type | Responsibility |
|---|---|
| `PluginHost` | The provider list, the enabled set, the script consent, and the plugin windows. Deliberately **not** on `AppState`. |
| `PluginScriptRunner` | Performs the IO for an already-resolved plan — LLM call, file write, subprocess, cursor insert. **No decisions**, so nothing testable is stranded outside `swift test`. |
| `PluginsPane` | Settings → Plugins, including the pre-enable disclosures and the script-consent switch. |
| Menu bar → Plugins | A submenu, present only when something is enabled. |

### The provider seam

`PluginHost` does not know about the compile-time registry. It enumerates
providers:

```swift
private static var providers: [PluginDiscovery.Provider] {
    [
        .init(source: .builtIn)  { PluginRegistry.builtInManifests },
        .init(source: .external) { PluginDiscovery.loadExternalManifests(in: externalDirectory) },
    ]
}
```

The registry is **one entry in that list**. The disk provider re-reads
`~/Library/Application Support/OpenWhisp/Plugins/<id>/manifest.json` on every
`reload()`, so a manifest dropped there shows up in the pane without a rebuild
or a relaunch. The **runner** (`PluginScriptRunner`) is now there too, so a
dropped-in script plugin doesn't just list — it runs. See
[Script plugins](#script-plugins).

Providers are passed in **descending trust order** and earlier wins, so a
writable directory can never shadow a reviewed plugin. That property is pinned
now, while nothing external can execute at all, because a future loader
inherits it.

The manifest describes an **entry point kind** (`builtIn` / `dynamicLibrary` /
`externalProcess`), never a Swift type name — so the schema does not assume the
plugin lives in this binary.

### Plugin seams

A plugin window opts into host behavior by conforming to small protocols:

| Protocol | What it gives the plugin |
|---|---|
| `PluginWindowLifecycle` | `pluginWindowWillShow()` on every open, including reopens of a cached window. |
| `PluginDictationSink` | Completed dictations land in the window while it is frontmost. |
| `PluginVoiceCommandSink` | A spoken command (`"create a meme …"`) invokes the plugin with a `PluginInvocationContext`. |

`PluginWindowLifecycle` exists because `PluginHost` caches window controllers
for the app's lifetime: without it, per-open setup runs once while per-close
teardown runs every time, and the imbalance silently poisons the window after
the first close.

---

## Manifest schema

`plugins/<id>/manifest.json`, and the literal in `PluginRegistry` for built-ins.
The two must agree — a test asserts it.

```json
{
  "id": "meme-generator",
  "name": "Meme Generator",
  "version": "0.5.0",
  "summary": "Dictate a meme description — the AI picks a template and writes the captions.",
  "symbol": "photo.badge.plus",
  "entry": "builtIn",
  "networkHosts": ["api.imgflip.com", "i.imgflip.com", "api.memegen.link"],
  "keyEquivalent": "m",
  "voiceTriggers": ["create a meme", "make a meme", "сделай мем"],
  "appAffinity": [],
  "clipboardAccess": false,
  "destination": "ownWindow"
}
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | **required** | Stable identifier. Also the on-disk directory name and the enablement key, so renaming it silently disables the plugin. Lowercase alphanumerics plus `-` and `.` only — it becomes a **path component**, so traversal-shaped ids are refused before being joined onto a URL. |
| `name` | string | **required** | Shown in the pane, the menu, and the window. |
| `symbol` | string | **required** | SF Symbol for every surface. Menu rows in this app always carry a symbol — never an emoji in the title. |
| `version` | string | `"0.0.0"` | Display only today; a future loader compares it against a compatibility floor. |
| `summary` | string | `""` | One line under the name. |
| `entry` | enum | `builtIn` | How the host runs it: `builtIn`, `script`, `dynamicLibrary`, `externalProcess`. `builtIn` runs only when compiled in; **`script` is the runnable kind for an installed plugin** — see [Script plugins](#script-plugins). An unknown value decodes to `unsupported`. |
| `steps` | [step] | `[]` | The pipeline a **script** plugin runs. Ignored for other entry kinds. See [the step schema](#the-step-schema). |
| `networkHosts` | [string] | `[]` | Hosts the plugin contacts. Rendered verbatim as a disclosure next to the enable toggle. Empty = fully local. **A label, not a sandbox.** |
| `keyEquivalent` | string? | `nil` | A single character **requested** as a ⌘-shortcut. The host decides — see below. |
| `voiceTriggers` | [string] | `[]` | Spoken **prefix** phrases that route a refine instruction here. |
| `appAffinity` | [string] | `[]` | **Reserved.** Bundle ids where the triggers are most relevant. Advisory; nothing routes on it yet. |
| `clipboardAccess` | bool | `false` | Whether the host passes the pasteboard to this plugin's invocations. |
| `destination` | enum | `ownWindow` | Where output goes. `cursor` and `outputTarget` are **reserved**. |

### Forward compatibility

Every field except `id` / `name` / `symbol` is optional, and an **unknown**
`destination` decodes to the default rather than throwing. This is the rule for
every future field: a manifest already sitting in a user's plugins folder must
keep working across an app update, because there is no migration path for a file
the app does not own.

### `keyEquivalent` — the plugin asks, the host decides

Only the host can see the whole menu, so a plugin cannot know that ⌘S is the
Scratchpad or ⌘, is Settings — and one that could silently shadow ⌘Q would be a
hazard rather than a papercut. Requests are resolved against the app's reserved
set (`q s , c x v a z` — what `AppMain` really binds) and then by list order,
first-wins.

A refusal is **silent** and costs only the shortcut, never the menu row. The
Plugins pane shows the **granted** shortcut, resolved through the same pass, so
it can never advertise a key the menu refused. A malformed value is reported by
`validate()` but is **not fatal** — losing a working plugin over a cosmetic
field would be the wrong trade.

### `voiceTriggers` — routing a dictation away from the editor

With refine armed, an instruction beginning with a declared phrase is handed to
the plugin instead of the refine LLM. Two flows:

| | You do | Material the plugin gets |
|---|---|---|
| **Selection** | select text → dictate → Refine → *"create a meme based on that"* | the selection |
| **Spoken** | Refine with nothing selected → *"create a meme expanding brain: typing, dictating, …"* | the spoken remainder |

Matching is deliberately strict, because a match **redirects a dictation away
from the user's editor** and a false positive costs them text:

- **prefix only** — *"summarize this, then create a meme"* stays a normal refine
- **word boundary** — *"create a **memo** about Q3"* does not match
- exact phrases, case/whitespace-insensitive; **no fuzzy matching**
- longest trigger wins, so a specific phrase can't be shadowed by a general one

Triggers are normalized (trimmed, lowercased, de-duped, empties dropped). That
normalization is load-bearing: an empty prefix would match **every** instruction
the user ever spoke. A list that normalizes away is reported but never fatal.

A non-match, a **disabled** plugin, or a window that can't take the command all
fall through to the untouched normal refine.

### `clipboardAccess` — declared, and actually gated

The host reads the pasteboard **only** for a plugin whose manifest declares it,
and the check happens *before* the read — an undeclared plugin causes no
`NSPasteboard` access at all. The rule lives in `PluginInvocationContext`, a
pure tested value, rather than at the AppKit call site where a forgotten `if`
would be invisible.

A plugin cannot distinguish "you didn't ask" from "the clipboard was empty".
Both arrive as `nil`, deliberately: a plugin able to tell them apart could probe
whether the user has anything copied.

Declaring it drives a visible disclosure in the pane, beside the network one.
The clipboard routinely holds passwords, tokens, and other people's messages, so
it is a bigger privacy fact than a network host.

### `destination` — one route implemented, two reserved

`ownWindow` is the only route the host can take. `cursor` and `outputTarget` are
carried and validated so the schema needn't change when the host learns to route
plugin output through the `OutputTarget` protocol the dictation pipeline already
uses. A manifest declaring one gets `validate() == .unsupportedDestination`,
stays **valid and runnable**, and `effectiveDestination` falls back to
`ownWindow` in a single place — refused honestly rather than silently rerouted.

---

## Script plugins

**The tier that delivers install-without-rebuild.** A folder in
`~/Library/Application Support/OpenWhisp/Plugins/<id>/` whose manifest says
`"entry": "script"` and declares a linear pipeline of steps. The host executes
every step; the plugin contributes no code to this process.

```json
{
  "id": "commit-message",
  "name": "Commit Message",
  "version": "1.0.0",
  "summary": "Turn a spoken description of a change into a commit message.",
  "symbol": "text.badge.checkmark",
  "entry": "script",
  "voiceTriggers": ["write a commit message"],
  "steps": [
    { "type": "llm", "prompt": "Rewrite as a git commit message:\n\n{{text}}" },
    { "type": "runScript", "script": "strip-fences.sh" },
    { "type": "insertAtCursor" }
  ]
}
```

A working example lives at `Tests/Fixtures/Plugins/commit-message/` — copy that
folder into the plugins directory to try it.

### The step schema

Steps compose **linearly**: the output of each is the input of the next, starting
from the invocation material (the spoken remainder, the selection, or both). A
step that delivers rather than transforms passes its input through unchanged, so
a pipeline can write a file *and* keep going.

| `type` | Extra fields | What the host does |
|---|---|---|
| `llm` | `prompt` | Runs the prompt through **your configured model**, via the same `summarizeResolved` path the Scratchpad uses. `{{text}}` is the step's input; a prompt without the token gets the input appended. |
| `runScript` | `script` | Runs a script **inside the plugin's own folder** through the hardened `ScriptRunner`: input on stdin, replacement on stdout, 2 s timeout, SIGTERM→SIGKILL. |
| `writeFile` | `file` | Appends or overwrites via `FileOutputTarget` — the same writer, heading tokens, and separator logic Settings → Files uses. `file` is `{ "path", "template", "mode" }`. |
| `insertAtCursor` | — | Pastes at the cursor in the frontmost app, the way a dictation lands. The output route for a plugin with no window. |

Every field but `type` is optional. A step with **no** `type` is the one fatal
case: no default for "what does this do" is safe when every option has side
effects, so the step list decodes to empty and the plugin is listed as broken
rather than partially run.

### Consent

The host owns every capability, so the pane states **before** the toggle exactly
what a script plugin will do — file paths, script filenames, cursor insertion,
model use. Those strings come from `PluginConsent` and are pinned by `swift
test`: a disclosure the view could quietly reword is not a disclosure.

**Running a shell script needs its own separate switch.** "I turned this plugin
on" is not the same statement as "I have read this script and agree it may run",
and folding the two together is how a plugins folder becomes an execution
vector. Consent is default-deny, stored under its own key, and **pruned on
reload** — delete a plugin and drop a different one in under the same id, and it
must ask again.

### Where a script may live

Inside the plugin's own directory, named by a relative path. No absolute paths,
no `~`, no traversal — checked syntactically *and* by resolving the path and
confirming it is still under the plugin folder, which catches combinations like
`a/../../b` that a component-wise check alone misses. `PluginScriptPath.resolve`
is the only thing that turns a declared script name into a URL.

This is the same seriousness the id validation gets, for the same reason: the
plugins directory is user-writable and this app holds Accessibility, microphone,
and clipboard rights. A manifest that could name `/usr/bin/osascript` would turn
"drop a JSON file in a folder" into arbitrary local execution.

### What an installed plugin still cannot do

An on-disk folder runs **only** as a script plugin. One declaring `"entry":
"builtIn"` is listed and refused, whatever it claims — a manifest cannot promote
itself into compiled code, and built-in still wins an id collision. So installing
a plugin gained exactly one capability (composing host actions) and no path at
all to the in-process execution `docs/ROADMAP.md` §6 rules out.

### Hot-swap: the manifest is re-read at invocation

The runner resolves from the manifest **on disk at the moment it runs**, not from
the copy the pane listed. Edit `manifest.json`, run the plugin again, and the
edit takes effect — no reload, no relaunch. This is called out because the
opposite bug (serving a value cached long after the source of truth changed) has
already shipped in this repo once.

### Forward compatibility

Both directions are handled, because a manifest in a user's folder has no
migration path:

| Situation | Behavior |
|---|---|
| Old manifest, new app | Decodes; `steps` defaults to empty. |
| **Unknown `entry`** (a newer OpenWhisp's kind) | Decodes to `unsupported`. Listed, refused with a reason. |
| **Unknown step `type`** | Carried as `unsupported(name)`. The plugin is listed and **refuses to run**, naming the step — running a pipeline with the unrecognized step silently skipped would be strictly worse. |
| Malformed `steps` | Degrades to no steps; the plugin is listed and refused. |

Note the `entry` case was a real bug fixed by this tier: `decodeIfPresent`
**throws** on an unrecognized enum value rather than returning nil, so before
this, a manifest saying `"entry": "script"` failed to decode and the plugin
vanished from the pane entirely.

---

## Writing an in-repo plugin

1. **Create `plugins/YourPlugin/`.** Everything here is app-layer: AppKit,
   SwiftUI, network, disk.
2. **Put the decisions in `OpenWhisp/Services/`** as Foundation-only types, and
   register each file in `Package.swift`'s `OpenWhispCore` `sources:` list. This
   is what makes the logic testable, and the list is explicit — an unregistered
   file is silently **untested**, not a build error.
3. **Write `plugins/YourPlugin/manifest.json`** and add the matching literal to
   `PluginRegistry.builtInManifests`. Assert the two agree.
4. **Add a window controller** and wire it into `PluginHost.open`'s switch — the
   one place a built-in plugin's window is constructed. Conform to whichever
   seams you need.
5. **Add tests** to `Tests/OpenWhispCoreTests/`. Drive the *same function the
   app calls*, not a re-implementation of its sequence — see below.
6. **Run the gates:** `swift test`, `./build.sh`, `PLUGINS=0 ./build.sh`, and
   `scripts/check-appstate-ratchet.sh`.

### The testing trap this system was built around

`plugins/` compiles only into the app and sits **outside** the `swift test`
target. A test that re-implements the app's sequence inside its own body proves
every piece in isolation and nothing about the chain — which is exactly how a
green suite once shipped a visibly broken plugin.

So: **extract the whole decision into one core function and have both the app
and the test call it.** In the meme plugin, `MemeCaptionSeeding.resolve` owns
the entire captions→boxes decision, `applyRanked` is a call to it plus UI glue,
and the test drives `resolve` directly. Anything left in `plugins/` should carry
no decisions worth testing.

For the parts that genuinely cannot be unit-tested — window lifecycle, network,
the LLM round-trip — there are runtime harnesses that drive the shipping binary
and print what each step decided: `scripts/meme-runtime-proof.sh` (the generate
path) and `scripts/meme-voice-command-proof.sh` (the trigger layer). Both need
`INSTRUMENTATION=1 ./build.sh`.

---

## Security and trust

**Plugins are runtime-opt-in.** Compiled in ≠ enabled: `PluginEnablement`
defaults to the empty set, so a default install ships the surface with nothing
switched on. Enabling is per-plugin, in the pane, next to that plugin's
disclosures.

**Provider trust ordering.** Providers are enumerated in descending trust order
and **earlier wins** an id collision, so a writable directory can never shadow a
reviewed plugin. This matters more than it looks: the external directory is
user-writable, and without the rule, dropping a folder named after a built-in
plugin would be code substitution against an app holding Accessibility,
microphone, and clipboard rights.

**External plugins run only as script plugins.** An on-disk folder is executed
only through the host's own step runner, never as compiled code: one declaring
`"entry": "builtIn"` is listed and refused no matter what it claims — **a
manifest cannot promote itself**. So the capability an installed plugin gained is
"compose actions the host already performs", and the one it did not gain is
in-process execution.

**`networkHosts` is disclosure, not a sandbox.** Nothing enforces it. It is an
honest label that drives a user-visible string, and it is only trustworthy
because every plugin in the tree is reviewed. The same caveat applies to
`clipboardAccess` in one direction: the host genuinely withholds the pasteboard
from a plugin that didn't declare it, but an **in-process** plugin could still
reach `NSPasteboard` itself. Enforcement only becomes real at a process
boundary.

**What third-party plugins require, and where the script tier stands:**

| Requirement | Status |
|---|---|
| A capability list the user consents to per-plugin | ✅ `PluginConsent` — disclosed before the toggle, with a separate switch for shell execution. |
| Enforcement **outside** the plugin's own manifest | ✅ For script plugins. The host performs every step, so the manifest *requests* and the host *decides* — a script plugin cannot exceed its declared steps because it never runs code that could. |
| A signature / provenance check | ❌ Not built. A dropped-in folder is trusted because the user put it there, and because what it can express is bounded. |
| A kill switch | ⚠️ Partial. Disabling stops it, and revoking script consent takes effect on the next invocation — but there is no remote or per-publisher revocation. |

The honest summary: for **script** plugins the trust question is answered by
*constraining what a plugin can express*, not by verifying who wrote it. That is
sufficient precisely because the step set is small and host-executed, and it is
why `dynamicLibrary` stays rejected — there is no equivalent bound on native code.

`networkHosts` remains the weak spot: a script plugin cannot make a network call
at all today (no step does), so the label is currently unreachable rather than
unenforced.

**Trigger surface is a scarce resource.** MAK-100 caps the exposed voice-tool
surface (~15), so the host must arbitrate ranking and the cap. `appAffinity` and
`voiceTriggers` are manifest **hints**; a plugin must never be able to
self-assign priority, for the same reason `networkHosts` is a label.

---

## Path to hot-swappable

**The shipping requirement is installing a plugin without rebuilding the app.**
The compile-time registry is fine while every plugin is in-repo, and it is not
the destination. This is the committed roadmap, not an open question.

### 1. Script / manifest-driven plugins — ✅ **SHIPPED**

A constrained action set the host executes over one input string. **Drop a
folder into the plugins directory, enable it, and it runs — no rebuild, no
relaunch.** That is the shipping requirement, and it is met.

- **Security:** the host owns every capability, so a plugin can only compose
  things the user already consented to. Reviewable by reading a manifest.
- **Limit:** can't express a live preview like the meme editor's. Good for text
  and actions, weak for custom UI — no declarative UI system was built, by
  design.

See [Script plugins](#script-plugins) for the schema, the steps, and the
consent rules.

### 2. Out-of-process plugin executables — **next**

A plugin is a helper binary the app launches and speaks to over a local
protocol; UI is contributed declaratively or by the plugin's own window.

- **Security:** the only option with real isolation. The plugin runs as its own
  process, gets its own sandbox profile, and does **not** inherit the host's TCC
  grants — a plugin cannot read the screen or the clipboard just because
  OpenWhisp can. A crash takes out the plugin, not the dictation pipeline.
- **Reuses what already ships:** the app bundles helper binaries at
  `Contents/Helpers/` (whisper, llama, the `openwhisp` CLI) and already has a
  local-socket protocol precedent in the Agent Bridge + MCP. Both precedents
  exist; this is assembly, not invention.
- **Cost:** an IPC surface and a UI-contribution schema. The real work.
- **Hard part:** signing. Third-party binaries need their own notarization
  story, or the host must run unnotarized helpers behind an explicit consent
  gate — a *policy* problem rather than an architecture one.

`PluginEntryKind.externalProcess` already exists in the schema for this.

### 3. WKWebView-hosted plugin UIs — optional UI layer

Plugin ships HTML/JS; the host exposes a narrow message-passing bridge. The web
sandbox is genuinely good and the bridge is an explicit allowlist, but a web
view is also a network egress the user may not expect, so CSP has to be locked
down. Pairs well with (2) — process for logic, web view for UI. Only if
declarative proves too limiting.

### 4. Loadable bundles / dylibs — **permanently ruled out**

`docs/ROADMAP.md` §6 rejects in-process third-party code outright, and nothing
here reopens it.

- **Security:** unacceptable. In-process code inherits Accessibility and
  clipboard rights wholesale — a plugin becomes a keylogger with the app's own
  consent prompts already granted.
- **Signing:** loading unsigned third-party code breaks the hardened runtime and
  library validation; the entitlement to permit it weakens the whole app.
- **ABI:** Swift has no stable ABI guarantee across a boundary you don't compile
  together, so every app update risks breaking every plugin.
- **Crash isolation:** none. A bad plugin crashes dictation.

### When plugins leave this repo

In-repo is right today: the meme plugin depends on `summarizeResolved`,
`ScratchpadAIModel`, `SummaryModelResolver`, and `BridgeWire.ErrorObject`, none
of which is a stable public API, and `swift test` covers the plugin's rules in
the same run as everything else. A separate repo would have to pin a contract
that does not exist yet.

The friction is real and worth naming: `plugins/` is outside `build.sh`'s glob
so it needs its own flag, and `Package.swift`'s explicit `sources:` list means
every pure file is registered by hand. Both are symptoms of the plugin being
neither fully in nor fully out.

Once the boundary is an IPC protocol rather than a Swift call, out-of-repo
becomes natural — **the protocol is the contract**, and that is the point at
which third-party plugins stop being a security question answered by reading
every diff.

---

## Build flags and testing

| Command | What you get |
|---|---|
| `./build.sh` | Plugins **on** (the default and the shipped configuration). |
| `PLUGINS=0 ./build.sh` | Lean build with no plugin surfaces at all. The pure plugin core still compiles and is still tested. |
| `INSTRUMENTATION=1 ./build.sh` | Adds the `MemeTrace` breadcrumbs and the runtime-proof probes. **Required** by the proof harnesses. |

`PLUGINS` is resolved by `scripts/plugin-source-args.sh`, shared by `build.sh`
and `build-dmg.sh` so the release DMG and a local build never drift.

`scripts/verify-plugins-binary.sh` runs in `package.sh` and `build-dmg.sh` and
fails the build if the plugin symbols are missing. Plugins live outside the
`OpenWhisp/` glob, so a broken source list produces a **working app with an
empty Plugins pane and no error** — the guard turns that silent failure into a
loud one.

### CI

| Job | Covers |
|---|---|
| `test` | `swift test` — every pure plugin rule. |
| `build-app` (lean, no plugins) | `PLUGINS=0` still compiles — the escape hatch can't rot. |
| `build-app-plugins` | The default, plugins-included build, plus the symbol verify. |
| `full-build` (nightly) | `./package.sh` full-fat, which runs the verify guards the release path uses. |

The two build jobs pin **opposite sides of the same flag** on purpose.
