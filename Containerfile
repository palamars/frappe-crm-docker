ARG FRAPPE_BRANCH=version-16
ARG FRAPPE_IMAGE_PREFIX=frappe

FROM ${FRAPPE_IMAGE_PREFIX}/build:${FRAPPE_BRANCH} AS builder

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

# One RUN layer per app - each has its own cache-bust arg (that app's resolved
# HEAD sha, computed in build.yml), so a commit to one app no longer forces a
# re-clone+reinstall of the others. Keep this block in sync with apps.json:
# adding/removing an app here means adding/removing both the matching entry
# in apps.json and the corresponding build-arg trio in build.yml.

ARG CRM_URL=https://github.com/palamars/crm
ARG CRM_BRANCH=main
ARG CRM_CACHE_BUST=""
RUN : "${CRM_CACHE_BUST}" && \
  bench get-app --branch ${CRM_BRANCH} ${CRM_URL} --skip-assets

ARG FLOW_URL=https://github.com/frappe/flow
ARG FLOW_BRANCH=develop
ARG FLOW_CACHE_BUST=""
RUN : "${FLOW_CACHE_BUST}" && \
  bench get-app --branch ${FLOW_BRANCH} ${FLOW_URL} --skip-assets

ARG ASSISTANT_URL=https://github.com/buildswithpaul/Frappe_Assistant_Core
ARG ASSISTANT_BRANCH=main
ARG ASSISTANT_CACHE_BUST=""
RUN : "${ASSISTANT_CACHE_BUST}" && \
  bench get-app --branch ${ASSISTANT_BRANCH} ${ASSISTANT_URL} --skip-assets

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

ARG ORGA_URL=https://github.com/tonic-6101/orga
ARG ORGA_BRANCH=main
ARG ORGA_CACHE_BUST=""
RUN : "${ORGA_CACHE_BUST}" && \
  bench get-app --branch ${ORGA_BRANCH} ${ORGA_URL} --skip-assets

# Asset build for everything installed above - the only step that must rerun
# whenever any single app layer changed, but it no longer re-clones/re-pip-installs
# the apps that didn't change.
RUN echo "{}" > sites/common_site_config.json && \
  bench build && \
  find apps -mindepth 1 -path "*/.git" | xargs rm -fr

FROM ${FRAPPE_IMAGE_PREFIX}/base:${FRAPPE_BRANCH} AS backend

USER frappe

COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

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
