# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

## Purpose

Hands-on evaluation lab for data catalog tools ([OpenMetadata](https://open-metadata.org/) and [DataHub](https://datahubproject.io/)) running on Podman. Not a production deployment. The layout mirrors `../object-storage/`: `setup/` holds the runnable environments, `evaluation/` holds the write-ups.

## Layout

```
setup/
├── lib/                 # env.sh (copy of object-storage/setup/lib/env.sh), common.sh, preflight.sh
├── openmetadata/        # run.sh, .env.example, compose.{upstream,override,altports}.yml, Containerfile.ingestion, configs/
├── datahub/             # same shape as openmetadata/
└── sample-db/           # PostgreSQL ingested by both tools: run.sh, .env.example, compose.yaml, sample-data/
evaluation/
├── docs/comparison.md   # findings (dated 2026-09-05; paths in its body are the pre-2026-11 layout)
└── plans/               # historical implementation plans (old paths, left as-is)
```

## Commands

Every directory under `setup/` (except `lib/`) is driven by `./run.sh` with settings in `.env` (copy from `.env.example`; precedence: shell env > `.env` / `ENV_FILE` > defaults).

```sh
./setup/sample-db/run.sh start
./setup/openmetadata/run.sh {start|stop|status|logs [svc...]|purge|ingest|fetch-compose [--force]|config [--show-secrets]}
./setup/datahub/run.sh      # same subcommands
./setup/lib/preflight.sh    # prerequisite check (every start runs it)
```

Requires Podman 4.7+, podman-compose 1.6.0+ (or docker compose 2.24+), `curl` / `python3` / `base64`. podman machine needs 6GB (OpenMetadata) / 8GB (DataHub). The two stacks collide on 3306 / 9200 / 8080 — don't run them together (`*_ALT_PORTS=1` exists but isn't recommended).

There is no build, lint, or test tooling; `start` / `status` / `ingest` embed their own checks.

## Conventions

- `compose.upstream.yml` is committed byte-for-byte from upstream (`run.sh fetch-compose`). All changes go in `compose.override.yml`, `compose.altports.yml`, or `.env` / `run.sh` defaults.
- `run.sh` is a thin compose wrapper. Compose variables it owns are declared with `env_var` and `export`ed (shell env beats `--env-file`); the loaded `.env` is also passed via `--env-file` so other upstream variables work.
- Ports cannot come from `.env`: podman-compose 1.6.0 does not expand `${VAR}` inside `!override` tags, so ports are literals in the override files.
- Keep `.env.example`, `run.sh` defaults, and `Containerfile.ingestion` versions in sync when bumping a tool version.
- Sample DB connection values are fixed (also hard-coded in each tool's `configs/`), not secrets.
- `setup/lib/env.sh` must stay identical to `../object-storage/setup/lib/env.sh` apart from its header note.
- Findings go in `evaluation/docs/comparison.md`, not scattered across other docs.
