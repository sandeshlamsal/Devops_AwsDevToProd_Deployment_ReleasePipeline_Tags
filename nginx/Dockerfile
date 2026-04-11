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

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -sf http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
