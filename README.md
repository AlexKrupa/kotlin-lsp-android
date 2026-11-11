# kotlin-lsp-android

`kotlin-lsp-android` helps Kotlin and Android projects in Neovim. A jump from project code into an
Android library, the Android SDK, or the Gradle API opens the source file, not a `.class` stub. The
user can select the Android build variant.

The repo has two parts:

- A Go binary. It sits between an LSP client and one shared `kotlin-lsp` server for each Gradle
  root.
- A small Neovim plugin. It opens `jar:` buffers and adds the command `:AndroidVariant`.

The binary is installed on PATH as `kotlin-lsp`. Neovim, Claude Code, and other LSP clients start
it with no change.

## Requirements

- The `kotlin-lsp` server from Homebrew: `/opt/homebrew/bin/kotlin-lsp`. The environment variable
  `KOTLIN_LSP_SERVER` sets another path.
- Gradle 9 or later in the projects. With an older Gradle, the projects get no library sources.
- A Gradle wrapper (`gradlew`) in each project root.
- Neovim 0.11 or later, with `zip` and `unzip` on PATH.
- Go, to build the binary.

## Install

1. Build the binary under the name `kotlin-lsp`:

   ```sh
   go build -o ~/.local/wrappers/kotlin-lsp ./cmd/kotlin-lsp-android
   ```

2. Put `~/.local/wrappers` on PATH before `/opt/homebrew/bin`. Then `kotlin-lsp` is this binary,
   not the Homebrew server.

3. Add the plugin with lazy.nvim:

   ```lua
   {
     dir = '~/src/kotlin-lsp-android',
     config = function()
       require('kotlin_lsp_android').setup()
     end,
   }
   ```

4. Use the plugin in the `kotlin_lsp` client config:

   ```lua
   vim.lsp.config('kotlin_lsp', {
     cmd = require('kotlin_lsp_android').cmd,
     root_dir = require('kotlin_lsp_android').root_dir,
   })
   ```

`cmd` starts `kotlin-lsp --stdio` in the root directory of the client. `root_dir` finds the Gradle
root of a buffer. For a library file in a jar, it uses the root of the last Kotlin buffer.

## Variants

The binary reads the build variants from the first import of the project. Until that import ends,
`variant list` fails.

| Command | Effect |
| --- | --- |
| `:AndroidVariant <name>` | Sets the variant. Completion lists the variants. |
| `:AndroidVariant` | Shows a picker (`vim.ui.select`) with the variants. |
| `kotlin-lsp variant list` | Prints the variants of the project in the current directory. |
| `kotlin-lsp variant set <name>` | Rejects an unknown name. Saves the variant, runs the Gradle run for the sources, and stops the server. |

The command works in the root of the `kotlin_lsp` client of the current buffer. If the buffer has
no client, it uses the root of the last Kotlin buffer.

After `set`, all Neovim instances of the root reconnect to a new server. The plugin shows this
message first. Then, in this Neovim instance, it starts the `kotlin_lsp` clients of the root again,
with the same buffers.

## Files

The cache root is `$KOTLIN_LSP_CACHE`. The default is `~/.cache/kotlin-lsp`. Each Gradle root has
the folder `<cache root>/<key>/`. The key is the first 12 hex characters of `sha256(root path)`.

Files in `<cache root>/<key>/`:

| File | Content |
| --- | --- |
| `lock` | Lock that lets clients that start at the same time share one server |
| `port` | TCP port of the server |
| `pid` | Process ID of the server |
| `server.log` | Log of the server |
| `variant` | The variant that `variant set` saved |
| `variants.json` | The variants of each module |
| `missing-sources.json` | The SDK and Gradle sources that the background download must fetch |
| `lsp-library-sources.gradle` | The init script that the binary writes at each start |
| `library-sources/workspace.json` | The libraries with their sources, for the server |
| `library-sources/fragments/` | The part of `workspace.json` of each Gradle build |
| `library-sources/empty/` | An empty content root for the module `lsp-library-sources` |
| `library-sources/java-sources/` | Copies of the Java files of sources jars that have a top folder, for example `main/` |

Files in `<cache root>/`, shared by all roots:

| File | Content |
| --- | --- |
| `gradle-sources/` | Extracted `src/main` folders of the Gradle source distributions |
| `download.log` | Log of the background downloads |
| `download.lock` | Lock that allows one download at a time |

## Limits

- One variant for the whole build. `kotlin-lsp` reads one variant name, so each module cannot have
  a different variant.
- No navigation in `.gradle.kts` files (kotlin-lsp issue #55).
- No `R` class in library modules (kotlin-lsp issue #280).
- No fixes or patches for `kotlin-lsp`: the repo only works around it.

## Tests

Go tests: `go test ./...`

Lua tests, with no user config:

```sh
nvim --clean --headless -l tests/jar_spec.lua
nvim --clean --headless -l tests/variant_spec.lua
```
