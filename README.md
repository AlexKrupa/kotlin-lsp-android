# kotlin-lsp-android

`kotlin-lsp-android` helps Kotlin and Android projects in Neovim. A jump from project code into an
Android library, the Android SDK, or the Gradle API opens the source file, not a `.class` stub. Go
to definition, hover, and references also work in `.gradle.kts` files. You can select the
Android build variant.

The repo has two parts:

- A Go binary. It sits between an LSP client and one shared `kotlin-lsp` server for each Gradle
  root.
- A small Neovim plugin. It opens `jar:` buffers, looks up names in `.gradle.kts` files, and adds
  the command `:AndroidVariant`.

The binary is installed on PATH as `kotlin-lsp`. Neovim, Claude Code, and other LSP clients start
it with no change.

The repo only works around kotlin-lsp. It does not fix or patch it.

## Requirements

- The `kotlin-lsp` server from Homebrew: `/opt/homebrew/bin/kotlin-lsp`. The environment variable
  `KOTLIN_LSP_SERVER` sets another path.
- Gradle 9 or later in the projects. With an older Gradle, the projects get no library sources.
- A Gradle wrapper (`gradlew`) in each project root.
- Neovim 0.11 or later, with `zip`, `unzip`, and `rg` on PATH.
- Go, to build the binary.
- The `android` CLI on PATH, for the background download of the Android SDK sources.
- `java` 17 or later on PATH, for the model of the `.gradle.kts` files.

## Install

1. Build the binary as `kotlin-lsp`, in a folder that is on PATH before `/opt/homebrew/bin`:

   ```sh
   go build -o ~/.local/wrappers/kotlin-lsp ./cmd/kotlin-lsp-android
   ```

2. Add the plugin with lazy.nvim. Set `executable` to the binary of step 1. Without it, the plugin
   takes `kotlin-lsp` from the PATH of Neovim, which can be the Homebrew server.

   ```lua
   {
     dir = '~/src/kotlin-lsp-android',
     config = function()
       require('kotlin_lsp_android').setup({ executable = vim.fn.expand('~/.local/wrappers/kotlin-lsp') })
     end,
   }
   ```

3. Use the plugin in the `kotlin_lsp` client configuration:

   ```lua
   vim.lsp.config('kotlin_lsp', {
     cmd = require('kotlin_lsp_android').cmd,
     root_dir = require('kotlin_lsp_android').root_dir,
   })
   ```

## Usage

### Variants

| Command | Effect |
| --- | --- |
| `:AndroidVariant <name>` | Sets the variant. Completion lists the variants. |
| `:AndroidVariant` | Shows a picker (`vim.ui.select`) with the variants. |
| `kotlin-lsp variant list` | Prints the variants of the project in the current directory. |
| `kotlin-lsp variant set <name>` | Saves the variant, runs Gradle for the library sources and the `R` jars, and stops the server. |

`:AndroidVariant` works in the root of the current buffer. `variant list` fails until the first
Gradle run of the root ends. After `set`, the `kotlin_lsp` clients in Neovim reconnect to a new
server with the same buffers. Other LSP clients lose the connection.

### Warm-up

`kotlin-lsp warmup` starts the server of the root of the current folder and waits for the import and
the indexing. To run it at each `cd` in fish, put this in `~/.config/fish/conf.d/`:

```fish
function __kotlin_lsp_warmup --on-variable PWD
    set -l top (git rev-parse --show-toplevel 2>/dev/null); or return
    test "$top" = "$__kotlin_lsp_warmup_top"; and return
    set -g __kotlin_lsp_warmup_top $top
    command kotlin-lsp warmup >/dev/null 2>&1 &
    disown
end
__kotlin_lsp_warmup
```

The command does nothing for a new clone, which has no cache folder, or for a root with a
running server.

### Root properties

To configure the server of a root, put the optional file `.kotlin-lsp.properties` in the root. Each
line is `key=value`. A line that starts with `#` is a comment.

```properties
heap=6g
```

| Key | Value | Default |
| --- | --- | --- |
| `heap` | Maximum heap of the server, in the format of `-Xmx`, for example `6g` or `4096m`. The binary adds `-Xmx<heap>` to `IJ_JAVA_OPTIONS` of the server, not of Gradle. | 2 GB, from `-Xmx2048m` in the `intellij-server.vmoptions` file of Homebrew |

The binary reads the file at each start of a server. A change applies after the next idle stop or a
stop of the server. If the file has an unknown key or an invalid value, the client does not start
and shows the error. To use one file in all worktrees of a repo, link it into each worktree.

### Gradle scripts

kotlin-lsp does not analyze `.gradle.kts` files (kotlin-lsp issue #55). In these files, the plugin
answers go to definition, hover, and references with a name lookup. The lookup uses the Gradle
script model, which the plugin writes with `kotlin-lsp script-model` after each import.

## Limits

- One variant for the whole build. `kotlin-lsp` reads one variant name. Each module cannot have a
  different variant.
- In `.gradle.kts` files, the navigation is a name lookup, not a compiler resolution. A jump can
  give more than one declaration, for example all overloads. A name in a block with no known
  receiver type goes to the implicit imports, the Kotlin DSL API, and `workspace/symbol`.
- The references from `.gradle.kts` files contain only the uses that go to the same declaration. A
  use that goes to an override of the declaration is not in the list.
- Neovim does not respond during a lookup in a `.gradle.kts` file. In
  [nowinandroid](https://github.com/android/nowinandroid), the first lookup in a Neovim session
  takes about 1 s: it reads the package lists of the jars and the package of each source file. A
  next lookup takes less than 0.1 s. The references do one lookup for each match of the name, for
  example 1.8 s for the 31 matches of `namespace`.
- After a `clean` or a new resource, the `R` class of an app changes only after a Gradle build of
  the app and the next server start. An import that changes the jar has no effect, because the
  server reads it only at its start.
- The `R` class of a library changes only after `kotlin-lsp variant set`, or after the first start
  that follows a delete of the cache folder of the root.

## Code

| Folder | Content |
| --- | --- |
| `cmd/kotlin-lsp-android/` | Entry point and subcommands |
| `internal/proxy/`, `internal/lsp/` | Message copy between a client and the server |
| `internal/server/` | Start, shared use, and idle stop of the server of a root |
| `internal/root/` | Gradle root of a folder |
| `internal/sources/` | Gradle run before the first start of a root |
| `internal/reimport/` | Import after a failed import |
| `internal/variant/`, `internal/warmup/`, `internal/scriptmodel/`, `internal/download/`, `internal/properties/` | One subcommand or one file each |
| `gradle/` | Init script and Tooling API client, embedded in the binary |
| `lua/kotlin_lsp_android/` | Neovim plugin |

[docs/architecture.md](docs/architecture.md) has the processes, the cache folder, and measurements.

## Tests

Go tests: `go test ./...`

Init script tests, with `ANDROID_HOME` set: `cd gradle-test && ./gradlew test`

Lua tests, with no user configuration:

```sh
nvim --clean --headless -l tests/jar_spec.lua
nvim --clean --headless -l tests/retry_spec.lua
nvim --clean --headless -l tests/root_spec.lua
nvim --clean --headless -l tests/script_lookup_spec.lua
nvim --clean --headless -l tests/script_model_spec.lua
nvim --clean --headless -l tests/sources_spec.lua
nvim --clean --headless -l tests/start_spec.lua
nvim --clean --headless -l tests/variant_spec.lua
```
