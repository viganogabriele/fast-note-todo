# Omanote Plus

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Omanote Plus adds a secure multiline scratch note *and* a to-do list to the
Omarchy bar, and saves both automatically.

![Omanote Plus screenshot](preview.png)

## Credit

This is a fork of [Omanote](https://github.com/brianblakely/omanote) by
Brian Blakely (MIT-licensed) — the note view, its Secret Service storage,
and the panel plumbing are his. The added To-Do tab (add/complete/delete,
drag-to-reorder, inline editing, its own storage field) is new here. See
[LICENSE](LICENSE) for the original copyright notice.

## Install

```bash
omarchy plugin add https://github.com/viganogabriele/omanote-plus.git --enable --yes
```

## Shortcuts

```lua
o.bind("SUPER + F8", "Toggle Omanote", "omarchy-shell shell toggle io.github.viganogabriele.omanote-plus")
o.bind("SUPER + ALT + F8", "Open Omanote", "omarchy-shell shell summon io.github.viganogabriele.omanote-plus")
o.bind("SUPER + CTRL + F8", "Close Omanote", "omarchy-shell shell hide io.github.viganogabriele.omanote-plus")
```

## Security

Notes and to-dos are stored in the desktop Secret Service rather than
`~/.config/omarchy/shell.json`. Automatic saves use a randomly named file in the
user runtime directory and delete it immediately afterward. The keyring
attribute is still `b.omanote` (the pre-fork plugin id) so a note saved
before the fork stays reachable after upgrading.

## Update

```bash
omarchy plugin update io.github.viganogabriele.omanote-plus
```

## Uninstall

```bash
omarchy plugin remove io.github.viganogabriele.omanote-plus
```
