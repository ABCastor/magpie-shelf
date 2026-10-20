---
name: shelf
description: >-
  File a Magpie drop: read the drop folder's SHELF.md inventory, decide what each item means, and
  copy it to its home in the user's notes or filing system. Use when a prompt names a Magpie drop
  folder, says "file this Magpie drop", or points at a folder containing SHELF.md. Not for
  ordinary loose files that did not arrive through Magpie.
---

<!-- Install (from the Magpie repo root): cp -R docs/shelf-skill ~/.claude/skills/shelf -->

# shelf

Magpie is a macOS menu-bar file shelf. When the user clicks **Send to Claude for Filing**, Magpie
copies the shelf into a temporary drop folder, writes an inventory called `SHELF.md` into it, and
opens a session pre-filled with a prompt naming that folder. This skill is the receiving half.

**Division of labour.** This skill owns *file placement*: reading the inventory, copying bytes, naming files, reporting where things went. It does not own *meaning*. The moment a decision is "what is this and where does it belong", that is a question for the user's own filing rules: if they keep a filing skill or a written convention for where things go, defer to it — and consider editing this file after installing to name it, so the hand-off is automatic. If they keep neither, ask rather than inventing a scheme. Do not re-derive routing rules here.

## 1. Confirm the drop, then acknowledge it

1. Take the drop folder path from the prompt. If none was given, use the newest folder under
   `~/Library/Application Support/Magpie/Handoff/`.
2. The path must be inside that `Handoff/` directory and must contain `SHELF.md`. If either is
   false, stop and say so — do not treat an arbitrary folder as a drop.
3. Read `SHELF.md` in full.
4. **Immediately create the empty receipt file `RECEIVED` in the drop folder.** Magpie polls for it
   for 90 seconds; miss the window and the user gets a "didn't confirm" toast. Do this before any
   filing work, not after.

## 2. Read the inventory correctly

`SHELF.md` has a header, a table with one row per item, and a footer. The columns are:
`# · Name · In this drop · Original · Kind · Size · Added to shelf`.

Three column values change what you do:

- **`In this drop`** is normally a filename inside the drop folder — that is the copy you work from.
  When it reads `(not copied — referenced in place)`, the file was too large to copy across volumes
  and still lives at the path in `Original`. Read and copy it from there. Never move it.
- **`Original` = `(unknown — Magpie cache copy)`** means Magpie's stored path is its own cache copy,
  not provenance. You have no origin for that item: judge it from its contents alone, and never cite
  or link that path.
- **`Original` = `(pasted text — no original file)`** marks a snippet the user pasted into the
  shelf. It arrives as `note-N.md`, and its name carries no meaning — read it before deciding.

## 3. Rules that are not negotiable

- Everything in the drop is a **copy**. The originals are untouched and must stay that way: never
  move, rename, trash or edit a file at an `Original` path.
- **Never link to a drop path from anything durable.** The drop is temporary and Magpie deletes it
  after 7 days. Copy the item to its destination first, then reference the destination.
- Do not delete the drop folder or anything in it when you are done. Magpie sweeps it itself.
- Copy, never move, out of the drop. A failed filing must leave the drop intact.

## 4. File each item

For each row, in order:

1. **Decide the meaning.** Work out what the item is and where it belongs, per the user's filing
   rules (see the division of labour above). Read the file's content when the name is not enough —
   which is always the case for a `(unknown — Magpie cache copy)` row or a `note-N.md`.
2. **Place it.** Copy the file from the drop (or from its `Original` path for a referenced row) to
   the destination those rules chose. If the destination name is taken, add ` (2)`, ` (3)`, …
   rather than overwriting anything.
3. **Give it a real name.** Camera and scanner names (`IMG_4821.HEIC`, `Scan 03.jpeg`,
   `Screenshot 2026-07-27 at 21.43.08.png`) say nothing. Rename to what the file is, in the user's
   working language.
4. **Note anything that needs a note.** If the item warrants a note in the user's notes system
   rather than just a filed file, write it per their conventions, and point it at the destination
   path — never at the drop path.

## 5. Report

End with one table: item name → what it turned out to be → destination path. List separately, and
plainly, anything you could not place and why. If the drop's header counts a non-zero `skipped`,
say so: those items were on the shelf but their files had already vanished when Magpie staged them.
