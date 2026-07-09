# frappe-crm-docker

Build pipeline for a custom Frappe production image (frappe + [palamars/crm](https://github.com/palamars/crm)), built via [frappe/frappe_docker](https://github.com/frappe/frappe_docker)'s `images/layered/Containerfile` and pushed to GHCR.

- `apps.json` — apps to bake into the image. Add more `{url, branch}` entries here and push to rebuild.
- `.github/workflows/build.yml` — checks out `frappe_docker` fresh on every run, builds, pushes to `ghcr.io/palamars/frappe-crm:16`.

Repo must stay **public** — GHCR package storage is free/unlimited for public packages on GitHub Free, capped at 500MB for private ones, and this image is well over that.
