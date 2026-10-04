# syntax=docker/dockerfile:1
#
# Strata's upstream image (strata-upstream:<ref>, built by launch-server.sh from
# Strata's own Dockerfile) plus the local patches in patches/, with the engine
# recompiled. Each patch says why it exists; drop it once upstream has the fix.

ARG STRATA_REF
FROM strata-upstream:${STRATA_REF}

WORKDIR /opt/strata
COPY patches/ /opt/strata-local/patches/
COPY rebuild_engine.py /opt/strata-local/

RUN for p in /opt/strata-local/patches/*.patch; do patch -p1 --forward < "$p" || exit 1; done \
    && .venv/bin/python /opt/strata-local/rebuild_engine.py

# Patches to Strata's scripts: no engine rebuild, so they live in their own layer.
COPY script-patches/ /opt/strata-local/script-patches/
RUN for p in /opt/strata-local/script-patches/*.patch; do patch -p1 --forward < "$p" || exit 1; done
