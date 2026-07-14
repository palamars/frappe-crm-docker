ARG FRAPPE_BRANCH=version-16
ARG FRAPPE_IMAGE_PREFIX=frappe

FROM ${FRAPPE_IMAGE_PREFIX}/build:${FRAPPE_BRANCH} AS bench-base

ARG FRAPPE_BRANCH=version-16
ARG FRAPPE_PATH=https://github.com/frappe/frappe
ARG FRAPPE_CACHE_BUST=""

USER frappe

# Bare frappe framework only, no apps yet - stays cached across builds unless
# frappe/frappe's own branch head moves (see FRAPPE_CACHE_BUST in build.yml).
RUN : "${FRAPPE_CACHE_BUST}" && \
  bench init \
    --frappe-branch=${FRAPPE_BRANCH} \
    --frappe-path=${FRAPPE_PATH} \
    --no-procfile \
    --no-backups \
    --skip-redis-config-generation \
    --skip-assets \
    --verbose \
    /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

# --- One independent build stage per app, all forked from bench-base. Because
# these stages don't depend on each other, BuildKit both caches and (where
# runner CPU allows) executes them in parallel, and adding/removing/reordering
# an app here never invalidates any other app's cache - unlike a single RUN
# chain, where every app after the changed one would also be forced to rerun.
# To add an app: add its own app-<name> stage below, then a COPY+pip line in
# the "assembled" stage, then a matching apps.json entry + build-arg trio in
# build.yml. ---

FROM bench-base AS app-crm
ARG CRM_URL=https://github.com/palamars/crm
ARG CRM_BRANCH=main
ARG CRM_CACHE_BUST=""
RUN : "${CRM_CACHE_BUST}" && \
  bench get-app --branch ${CRM_BRANCH} ${CRM_URL} --skip-assets

FROM bench-base AS app-flow
ARG FLOW_URL=https://github.com/frappe/flow
ARG FLOW_BRANCH=develop
ARG FLOW_CACHE_BUST=""
# litellm>=1.92 ships a mandatory Rust extension (pyo3-ffi) that doesn't yet
# support this image's Python (3.14), which breaks `bench get-app`'s own
# unconstrained dependency resolution. flow's own constraint on litellm
# (>=1.83.0,<2) is loose enough that pinning below 1.92 still satisfies it,
# and 1.91.3 is the last pure-Python release (no Rust build needed at all),
# so clone flow ourselves and install it with that upper bound instead of
# letting `bench get-app` pick the newest (currently broken) version.
RUN : "${FLOW_CACHE_BUST}" && \
  git clone --branch ${FLOW_BRANCH} --depth 1 --origin upstream ${FLOW_URL} apps/flow && \
  echo "litellm<1.92" > /tmp/flow-constraints.txt && \
  uv pip install --quiet -e apps/flow -c /tmp/flow-constraints.txt --python /home/frappe/frappe-bench/env/bin/python

FROM bench-base AS app-assistant
ARG ASSISTANT_URL=https://github.com/buildswithpaul/Frappe_Assistant_Core
ARG ASSISTANT_BRANCH=main
ARG ASSISTANT_CACHE_BUST=""
RUN : "${ASSISTANT_CACHE_BUST}" && \
  bench get-app --branch ${ASSISTANT_BRANCH} ${ASSISTANT_URL} --skip-assets

FROM bench-base AS app-dock
ARG DOCK_URL=https://github.com/tonic-6101/dock
ARG DOCK_BRANCH=develop
ARG DOCK_CACHE_BUST=""
# Dock Settings ships with issingle:0 upstream even though dock/orga's own code
# treats it as a Single - https://github.com/tonic-6101/dock/issues/1. Patch it
# here so the fix survives image rebuilds instead of being reapplied by hand.
RUN : "${DOCK_CACHE_BUST}" && \
  bench get-app --branch ${DOCK_BRANCH} ${DOCK_URL} --skip-assets && \
  sed -i 's/"engine": "InnoDB",/"engine": "InnoDB",\n "issingle": 1,/' \
    apps/dock/dock/dock/doctype/dock_settings/dock_settings.json

FROM bench-base AS app-orga
ARG ORGA_URL=https://github.com/tonic-6101/orga
ARG ORGA_BRANCH=main
ARG ORGA_CACHE_BUST=""
RUN : "${ORGA_CACHE_BUST}" && \
  bench get-app --branch ${ORGA_BRANCH} ${ORGA_URL} --skip-assets

# --- Merge stage: bring every app's cloned+pip/yarn-installed source together
# (cheap layer copies), re-register each into this stage's own venv (no
# network clone/yarn needed here, just editable-install bookkeeping), then
# build assets once for everything - the one step that always reruns when any
# app changed, but it no longer forces a re-clone/re-yarn of the others. ---

FROM bench-base AS assembled

COPY --from=app-crm --chown=frappe:frappe /home/frappe/frappe-bench/apps/crm apps/crm
COPY --from=app-flow --chown=frappe:frappe /home/frappe/frappe-bench/apps/flow apps/flow
COPY --from=app-assistant --chown=frappe:frappe /home/frappe/frappe-bench/apps/frappe_assistant_core apps/frappe_assistant_core
COPY --from=app-dock --chown=frappe:frappe /home/frappe/frappe-bench/apps/dock apps/dock
COPY --from=app-orga --chown=frappe:frappe /home/frappe/frappe-bench/apps/orga apps/orga

RUN uv pip install --quiet \
    -e apps/crm \
    -e apps/flow \
    -e apps/frappe_assistant_core \
    -e apps/dock \
    -e apps/orga \
    --python /home/frappe/frappe-bench/env/bin/python && \
  printf 'frappe\ncrm\nflow\nfrappe_assistant_core\ndock\norga\n' > sites/apps.txt && \
  echo "{}" > sites/common_site_config.json && \
  bench build && \
  find apps -mindepth 1 -path "*/.git" | xargs rm -fr

FROM ${FRAPPE_IMAGE_PREFIX}/base:${FRAPPE_BRANCH} AS backend

USER frappe

COPY --from=assembled --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

# Move assets to image-layer storage
RUN cp -r /home/frappe/frappe-bench/sites/assets /home/frappe/frappe-bench/assets && \
  rm -rf /home/frappe/frappe-bench/sites/assets

VOLUME [ \
  "/home/frappe/frappe-bench/sites", \
  "/home/frappe/frappe-bench/logs" \
]

USER root
# This entrypoint script link build assets of the image to the mounted sites volume at container initialization
COPY resources/core/main-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

COPY resources/core/start.sh /usr/local/bin/start.sh
RUN chmod 755 /usr/local/bin/start.sh

USER frappe
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["start.sh"]
