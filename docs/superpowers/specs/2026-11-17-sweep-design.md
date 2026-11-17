# Sweep: Mac cleaner app (design)

Date: 2026-11-17. Target: this Mac mini M4, macOS 26, Swift command line tools only (no Xcode).

## Goal
A small native app that frees disk space and shows memory use. The user scans, reviews, then cleans.

## Build
Swift package with two targets: `SweepCore` (all logic, tested) and `Sweep` (SwiftUI window). `make-app.sh` builds a release binary and wraps it in `Sweep.app`.

## Sections
| Section | Scans | Removal |
|---|---|---|
| System junk | `~/Library/Caches/*`, `~/Library/Logs/*` over 1 MB | Trash |
| Developer junk | npm, yarn, pnpm, bun, gradle, cargo caches, `~/.cache/*`, Xcode DerivedData, simulator caches; `node_modules`, `.next`, `DerivedData` under `~/Projects` in projects untouched 30+ days | Trash |
| Large & old files | Downloads, Desktop, Documents: files over 100 MB, or over 10 MB and not opened in 180 days | Trash |
| Duplicates | Same three folders, files over 1 MB with identical SHA-256 | Trash |
| System-wide caches | `/Library/Caches/*`, `/Library/Logs/*` | Permanent, via the macOS admin password prompt |
| Uninstall apps | Apps in `/Applications` and `~/Applications` plus exact-match leftovers in `~/Library` | Trash |
| Memory | Used/total RAM, top processes, Quit button, admin `purge` | n/a |
| Docker | `docker system df`; `docker system prune -f` | Permanent, confirmed |
| Schedule | Off, daily or weekly launchd job running `Sweep --auto-clean` | Permanent, caches and logs only |

## Safety rules
- Trash removals only accept paths at least two levels inside the home folder (three inside `~/Library`), or a top-level `.app` in `/Applications`.
- Admin deletes only accept paths strictly inside `/Library/Caches/` or `/Library/Logs/`. The app never handles the password; macOS prompts for it.
- `com.apple.*` entries and caches of running apps are skipped.
- Nothing is pre-ticked. Permanent actions ask for confirmation.
- iCloud-only files are skipped so scanning never triggers downloads.
- Unreadable folders show a notice linking to Full Disk Access; the app works without it.

## Known limits
- "Untouched project" is judged from modification dates two levels deep, so a deep-only edit can be missed. Items go to the Trash, so this is recoverable.
- Process memory is resident size from `ps`, which differs slightly from Activity Monitor.
- Scheduled cleaning deletes permanently because trashed caches free no space.

## Testing
Swift Testing suite for the safety checks, admin script quoting, scanners and cleaner against temporary folders. `Sweep --scan` prints real totals for the non-private locations as a read-only smoke check. `Sweep --snapshot DIR` saves a PNG of each section for UI checks without Screen Recording permission.

## Build note
On the macOS 26 SDK, SwiftUI's `@State` is a macro whose plugin ships only with Xcode, so the app keeps all view state in one `ObservableObject` (`Model`) instead.
