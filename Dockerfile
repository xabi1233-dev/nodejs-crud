# Image for the Node.js CRUD app.
#
# Build:  docker build -t crud-app .
# Run:    docker compose up  (see docker-compose.yml — needs MySQL alongside)

FROM node:22-alpine

# Tiny init process so Ctrl+C and `docker stop` reach Node as a real signal
# rather than being swallowed by PID 1.
RUN apk add --no-cache tini

WORKDIR /app

# Copy the manifests alone first. Docker caches each layer, so dependencies are
# only reinstalled when these two files change — not on every source edit.
COPY --chown=node:node package.json package-lock.json ./

# `npm ci` installs exactly what package-lock.json pins, unlike `npm install`
# which may resolve newer versions. Reproducible builds need ci.
RUN npm ci --omit=dev && npm cache clean --force

COPY --chown=node:node . .

# Never run as root inside a container. The node image ships a `node` user.
USER node

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/health || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
