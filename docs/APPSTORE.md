# Mac App Store edition

Headroom ships two ways from the same code:

| | Download (Developer ID, notarized) | Mac App Store ("Headroom: Disk & Files") |
|---|---|---|
| Build | `scripts/bundle.sh` / `scripts/release.sh` | `scripts/appstore.sh` (`-DAPPSTORE`) |
| Bundle ID | `app.headroom.Headroom` | `com.saphaare.headroom` |
| Sandbox | no (Full Disk Access optional) | App Sandbox; folders open when you choose them |
| Updates | daily feed check, opens the download | the App Store |
| Memory, AI, Drives screens | yes | no — the sandbox can't see other processes, run tools or mount drives |
| Developer-tool cleanups (`simctl`, `docker`, `brew`…) | yes | no (`.command` findings are dropped) |
| Bundled `headroom-cli` | yes | no |

`Edition.appStore` (Sources/Headroom/Edition.swift) is the switch. Paths use `HeadroomPaths.home` (the real
home from the user database), never `NSHomeDirectory()`, which is the container inside the sandbox.
`FolderAccess` keeps security-scoped bookmarks for what you grant: Home asks for your home folder once;
workspace members you add or drop are remembered the same way. The entitlements
(scripts/appstore/Headroom.entitlements) open Downloads, Pictures, Movies and Music without asking.

## Signing assets (team M359MD8CXK, made with `asc`)

- Bundle ID `com.saphaare.headroom` — `LM8AYQX4U4` (`app.headroom.Headroom` belongs to someone else on the App Store)
- Apple Distribution certificate `5Y8DGRLBWH`, Mac Installer Distribution `8C68566B5C` (to Oct 2027);
  private keys in `~/.headroom-signing` (mode 600) and the login keychain — never in the repo
- Provisioning profile "Headroom Mac App Store" `43HLS8GWKX` → `~/.headroom-signing/Headroom_AppStore.provisionprofile`

Renew next year with the same commands (`asc certificates create --certificate-type DISTRIBUTION|MAC_INSTALLER_DISTRIBUTION
--generate-csr …`, `asc profiles create --profile-type MAC_APP_STORE …`).

## Build and upload

```bash
scripts/appstore.sh             # dist/Headroom-AppStore.pkg (universal, sandboxed, signed)
scripts/appstore.sh --upload    # …and upload it with asc (the app record must exist)
```

The build number is the commit count, so commit before each upload. A Distribution-signed app won't launch
outside the App Store; to try the sandbox locally, copy `dist/appstore/Headroom.app`, drop
`embedded.provisionprofile` and the two identifier keys from the entitlements, and sign it ad hoc with them.

## The app record

Created: app ID `6824259373`, SKU `HEADROOM-MAS` — https://appstoreconnect.apple.com/apps/6824259373

Creating an app needs a web session (`asc web auth login --apple-id …`, with your 2-factor code), then
`asc web apps create --name "Headroom: Disk & Files" --bundle-id com.saphaare.headroom --sku HEADROOM-MAS`.

## Listing (en-US)

- **Name:** Headroom: Disk & Files
- **Subtitle (30):** See where every GB goes
- **Category:** Utilities (secondary: Productivity) · **Price:** Free · **Age rating:** 4+
- **Privacy:** Data Not Collected · policy: https://github.com/everyai-com/headroom/blob/release-1.0/docs/PRIVACY.md (main once merged)
- **Support URL:** https://github.com/everyai-com/headroom/issues
- **Keywords (100):** space,storage,cleaner,duplicates,search,downloads,tidy,desktop,large files,workspace,organizer
- **Promotional text:** Your Mac's disk, explained — and your files, finally findable. Everything stays on your Mac.

**Description**

Headroom shows where every gigabyte on your Mac goes, helps you get space back safely, and makes your own
files easy to find.

YOUR FILES, BY KIND
Images, videos, music, documents and archives on shelves with big previews. Quick Look with Space, a live
inspector, and drag several files out at once.

SEARCH THE WAY YOU'D SAY IT
"pdfs from last week over 5 mb", "screenshots with wifi password", "zips older than 6 months". Headroom shows
how it read you as chips you can take off. It even finds the words inside your screenshots — read on your Mac.

QUICK SEARCH FROM ANYWHERE
Press ⌃⌥Space in any app for files, apps and System Settings pages in one place.

WORKSPACES
Put a project's folders and files on one page, wherever they live — Documents, Downloads, iCloud Drive or a
drive. Nothing is copied or moved. See what changed lately at a glance. ⌃1–⌃9 to jump between them.

TIDY THE DESKTOP
One click puts loose files into folders by kind — Screenshots, Images, PDFs, Documents, Installers. You see the
plan first, and Undo puts everything back.

DUPLICATES AND CLEAN-UP
Identical files and look-alike photos, old installers, forgotten downloads, old screenshots and big old videos,
each on a card with what it frees. Everything goes to the Trash, never deleted for good, with Undo.

SEE THE WHOLE DISK
A map of every folder by size, plain-English explanations of what any folder is and whether it's safe to
remove, and a notch and menu bar glance at your free space.

PRIVATE BY DESIGN
No accounts, no analytics, no network. Text recognition and duplicate detection run on your Mac.

## Review notes

Headroom is a file browser and disk-space utility. On first launch, Home asks the reviewer to choose their
home folder (security-scoped bookmark) — after that the library, search, Workspaces (⌥⌘N), Tidy (⌥⌘T on the
Desktop) and Duplicates (⇧⌘D) work. Every removal goes to the Trash after a confirm and can be put back from
Activity. The app lives in the menu bar and the notch (LSUIElement); open the window from the menu bar icon.
No sign-in, no network access.

## Screenshots

Saved in docs/appstore/screenshots. Remake with `Headroom --render <dir> --demo --store` from the App Store build (2880×1800, the App Store edition's screens on made-up demo files, so
no real files appear) after `scripts/demo-seed.sh`.
