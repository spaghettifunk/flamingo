# Optional Font Assets

Flamingo does not need a bundled font file to run.

Because Flamingo is a terminal UI, it cannot switch your terminal emulator's font at runtime. Terminals choose fonts through their own settings. Configure your terminal to use a Nerd Font, then set:

```toml
[ui]
icon_mode = "nerd_font"
```

You can also test a mode for one launch with:

```sh
FLAMINGO_ICON_MODE=nerd_font flamingo
```

Do not add third-party font binaries here unless the license and repository size impact have been reviewed.
