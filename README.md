# Omanote

Omanote adds a secure multiline scratch note to the Omarchy bar and saves changes automatically.

![Omanote screenshot](images/omanote.png)

## Install

Omanote requires `secret-tool`, provided by the `libsecret` package.

```bash
omarchy plugin add https://github.com/brianblakely/omanote.git
```

Accept the prompt to enable Omanote. Omarchy places it in the right bar section by default.

## Optional shortcuts

Global keybindings remain user-owned. Add any of these to your Hyprland bindings:

```lua
o.bind("SUPER + F8", "Toggle Omanote", "omarchy-shell shell toggle b.omanote")
o.bind("SUPER + ALT + F8", "Open Omanote", "omarchy-shell shell summon b.omanote")
o.bind("SUPER + CTRL + F8", "Close Omanote", "omarchy-shell shell hide b.omanote")
```

## Storage and behavior

Omanote runs `bash` and `secret-tool`. It stores the note with the desktop Secret Service using the attributes `omarchy-plugin=b.omanote` and `field=note`.

Automatic saves briefly stage the note in a randomly named file under `$XDG_RUNTIME_DIR`, pipe it into `secret-tool store`, and delete the runtime file immediately afterward. Note contents are never stored in `~/.config/omarchy/shell.json`. Omanote does not use the network.

Plugins run unsandboxed inside `omarchy-shell`; review the source before installing it.

## Update

```bash
omarchy plugin update b.omanote
```

## License

[MIT](LICENSE)
