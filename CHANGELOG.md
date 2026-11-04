# Changelog

## 0.4.0

### Breaking changes

The redis service has been removed from the chart since control plane no longer needs it.

### Upgrading from 0.3.x

- Do `helm upgrade` to delete the `<release>-redis` resources.
- Remove `redis.*` and `control.config.redis.*` from your values file. Helm ignores these keys and does not show an error.
- If you use an external Redis, the control plane stops using it after the upgrade. You can remove the `redis-url` key from your Secret.
- If you pin `image.tag`, use a control image that accepts a `control.toml` without a `[redis]` section (strictly newer than `v2026-11-03`).
