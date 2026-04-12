FROM nginx:1.25-alpine

# Build-time version metadata — baked in as defaults, can be overridden by K8s env vars
ARG APP_VERSION=unknown
ARG BUILD_SHA=unknown
ARG ENV_NAME=unknown
ARG BUILD_DATE=unknown

ENV APP_VERSION=${APP_VERSION} \
    BUILD_SHA=${BUILD_SHA} \
    ENV_NAME=${ENV_NAME} \
    BUILD_DATE=${BUILD_DATE}

# Install tools: gettext for envsubst, curl for healthcheck
RUN apk add --no-cache gettext curl

# Nginx config
COPY nginx.conf /etc/nginx/nginx.conf

# HTML template and entrypoint
COPY html/index.html.template /usr/share/nginx/html/index.html.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

# nginx must run as root to bind port 80 — no USER instruction is intentional.
# nosemgrep: dockerfile.security.missing-user.missing-user
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -sf http://localhost/health || exit 1

# nginx master process must run as root to bind port 80; workers run as the
# built-in 'nginx' user (UID 101). Suppressing the missing-user finding here
# because switching to an unprivileged port (8080) is out of scope.
# nosemgrep: dockerfile.security.missing-user-entrypoint.missing-user-entrypoint
ENTRYPOINT ["/entrypoint.sh"]
