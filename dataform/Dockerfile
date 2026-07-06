# Container for the Dataform transform Cloud Run job.
# Bundles the Dataform project so the monorepo stays the single source of truth
# (no separate Git repo, no managed-Dataform git-root constraint).
FROM node:20-slim

WORKDIR /dataform
COPY . /dataform/

# Dataform Core 3.x resolves @dataform/core from the CLI bundle (no `dataform
# install`, no package.json). Compile at build to fail fast + warm the image.
RUN npm install -g @dataform/cli@3.0.0 \
 && sed -i 's/\r$//' /dataform/run.sh && chmod +x /dataform/run.sh \
 && dataform compile

ENTRYPOINT ["/dataform/run.sh"]
