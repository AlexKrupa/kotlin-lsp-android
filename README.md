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
- Neovim 0.11 or later, with `zip`, `unzip`, and `rg` on PATH.
- Go, to build the binary.
- The `android` CLI on PATH, for the background download of the Android SDK sources.

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
       require('kotlin_lsp_android').setup({ executable = vim.fn.expand('~/.local/wrappers/kotlin-lsp') })
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

`cmd` starts `kotlin-lsp --stdio` in the root directory of the client. Without `executable`, it
takes `kotlin-lsp` from the PATH of Neovim, which can be the Homebrew server. `:AndroidVariant` uses
the same executable. `root_dir` finds the Gradle
root of a buffer. For a library file (a `jar:` buffer, or an Android SDK or Gradle source file), it
uses the root of the last Kotlin buffer.

`cmd` also has workarounds for library locations. They use only the sources in `workspace.json`:

- Sometimes kotlin-lsp locates a symbol in a class file, although `workspace.json` has sources for
  its jar. An example is the Kotlin stdlib of the Gradle distribution in build logic. Then `cmd`
  moves the location to the declaration in those sources. For overloads, it compares the signature
  in the decompiled class file.
- The server finds nothing for a jump from a library source file. Then `cmd` searches the name: in
  the imports, the file, the package, and the library. A name from another library goes to the
  server as a full name.

They extract a sources jar to the Neovim cache folder.

During the import and the indexing, kotlin-lsp can also locate a symbol in a class file. A later
jump gives the source. Then `cmd` opens the class file and shows a message. When the work done
progress (`$/progress`) of the client ends, `cmd` sends the request again. If the new result is a
source file and the class file is still the current buffer, `cmd` moves the cursor there. The
jumplist and the tagstack do not get the class file, so `<C-o>` and `<C-t>` go back to the start
of the jump. A class file location from outside the indexing gets no retry, because many libraries
have no sources.

## Variants

The binary reads the build variants from the first Gradle run of the init script: the separate run
at the first start, or the server import. Until that run ends, `variant list` fails.

| Command | Effect |
| --- | --- |
| `:AndroidVariant <name>` | Sets the variant. Completion lists the variants. |
| `:AndroidVariant` | Shows a picker (`vim.ui.select`) with the variants. |
| `kotlin-lsp variant list` | Prints the variants of the project in the current directory. |
| `kotlin-lsp variant set <name>` | Rejects an unknown name. Saves the variant, runs the Gradle run for the sources, and stops the server. |

The command works in the root of the `kotlin_lsp` client of the current buffer. If the buffer has
no client, it uses the root of the last Kotlin buffer.

`cmd` also has workarounds for library locations. They use only the sources in `workspace.json`:

- Sometimes kotlin-lsp locates a symbol in a class file, although `workspace.json` has sources for
  its jar. An example is the Kotlin stdlib of the Gradle distribution in build logic. Then `cmd`
  moves the location to the declaration in those sources. For overloads, it compares the signature
  in the decompiled class file.
- The server finds nothing for a jump from a library source file. Then `cmd` searches the name: in
  the imports, the file, the package, and the library. A name from another library goes to the
  server as a full name.

They extract a sources jar to the Neovim cache folder.

After `set`, all Neovim instances of the root reconnect to a new server. The plugin shows this
message first. When the server stops, each proxy exits with code 3. Then `cmd` starts the
`kotlin_lsp` client again, with the same buffers. Other LSP clients lose the connection.

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
| `library-sources/fragments/.lock` | Lock for the merge of the fragments |
| `library-sources/empty/` | An empty content root for the module `lsp-library-sources` |
| `library-sources/java-sources/` | Copies of the Java files of sources jars that have a top folder, for example `main/` |

Files in `<cache root>/`, shared by all roots:

| File | Content |
| --- | --- |
| `gradle-sources/` | Extracted `src/main` folders of the Gradle source distributions |
| `download.log` | Log of the background downloads |
| `download.lock` | Lock that allows one download at a time. A second download waits. |

## Limits

- One variant for the whole build. `kotlin-lsp` reads one variant name, so each module cannot have
  a different variant.
- No navigation in `.gradle.kts` files (kotlin-lsp issue #55).
- No `R` class in library modules (kotlin-lsp issue #280).
- No fixes or patches for `kotlin-lsp`: the repo only works around it.

## Tests

Go tests: `go test ./...`

Init script tests, with `ANDROID_HOME` set: `cd gradle-test && ./gradlew test`

Lua tests, with no user config:

```sh
nvim --clean --headless -l tests/jar_spec.lua
nvim --clean --headless -l tests/retry_spec.lua
nvim --clean --headless -l tests/sources_spec.lua
nvim --clean --headless -l tests/variant_spec.lua
```
