Consult USAGI.md and meta/usagi.lua for info about the game engine

The game is unreleased, no need to worry about backwards compatible save formats

Always ignore ideas.md, it's a scratchpad and should not factor into _any_ decisions

A race is a single instance of a player hitting all checkpoints unlocked on a track.
A loop is a Rebirth-to-Rebirth cycle: the player climbs the cash-gated tracks as far as their current power allows, then takes Rebirth to reset and climb again stronger

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `z0isch/ghost-racer`, driven via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, using their default label strings. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one root `CONTEXT.md` plus `docs/adr/`, both created lazily. See `docs/agents/domain.md`.
