# Quepasa native release notes — 2026-05-16

## Goal

Make the native Quepasa integration reliable for:

- new self-hosted installs using `delvechiotech/chatwoot-quepasa`
- the live `chat.delvechio.tech` environment

## Root causes found

1. Native Quepasa webhook jobs were processed on the `low` queue, which allowed visible delivery delays when the worker was busy.
2. New Quepasa inboxes defaulted to `read_sync: true`, which produced repeated Quepasa sync conflicts in the tested deployment.
3. The example Portainer stack mounted `/app/public`, which can mask image-bundled frontend assets after upgrades.
4. The example stack did not make Quepasa account credentials explicit, even though the native flow depends on them.
5. Windows-built Docker images can become non-runnable if shell scripts are copied with CRLF line endings.

## Code and packaging changes

- `Webhooks::QuepasaEventsJob` now uses the `high` queue.
- New Quepasa inboxes now default to `read_sync: false`.
- `Whatsapp::Quepasa::Client` no longer falls back to an instance-specific URL.
- The Portainer example stack:
  - removes `/app/public`
  - documents required Quepasa credentials
  - increases Sidekiq capacity
- Added:
  - native installation guide
  - standalone Quepasa stack example
  - `.gitattributes` to preserve Unix shell line endings

## Published image

- Immutable tag: `delvechiotech/chatwoot-quepasa:1.0.0`
- Digest: `sha256:f894723e969d10e6126838fed0f8c65ecac1a13b9e899e98232524c867db0a78`
- `latest` was updated to the same digest after runtime validation.

## Live Delvechio deployment

- Updated `chatwoot_app` and `chatwoot_sidekiq` to `1.0.0`
- Increased Sidekiq resources to:
  - `cpus: "2"`
  - `memory: 2048M`
- Confirmed the running production container contains:
  - `queue_as :high`
  - `read_sync: false`
- Updated existing inbox `72` to:
  - `automation_settings.read_sync = false`

## Operational notes

- Keep Quepasa pinned to a tested digest instead of floating on `latest`.
- Do not mount `/app/public` from an external volume in deployments that expect frontend updates from the image.
- For already-created inboxes, default changes do not rewrite historical provider config; update old inboxes explicitly when needed.
