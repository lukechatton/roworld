# Rofront

## Publish announcements (Discord)

User (2026-10-15): "whenever you ship to prod or staging, start sending a message to our company discord ... a
list/summary of the changes", narrowed the same day: "change publish discord message rule to only send when shipping
to prod". So: **prod only**; a staging publish is not announced.

- Right after every successful publish / deploy to **prod**, post it with the shared script
  (`~/.local/bin/snick-announce`, used by every Snick project):
  `snick-announce --project "RoWorld" --target prod [--version vN] [--ref <commit>] --notes-file notes.md [--extra "Restart: ..."]`
  (after `tools/publish.sh` succeeds without `--staging`). User (2026-10-25): "publish messages should use
  "RoWorld" instead of "RoFront"" (the game's current name; posts up to v101 said Rofront).
- Notes: one "- " line per change, in plain words for the team (what players / visitors notice), not commit messages.
- The webhook lives in `~/.config/snick/discord_publish_webhook` (chmod 600): never print it, never commit it.
- A failed post never undoes the publish: retry, or tell the user it wasn't announced.
