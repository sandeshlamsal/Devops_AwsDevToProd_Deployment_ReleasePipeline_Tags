#!/bin/sh
set -e

HTML_DIR="/usr/share/nginx/html"
TEMPLATE="${HTML_DIR}/index.html.template"
OUTPUT="${HTML_DIR}/index.html"
VERSION_JSON="${HTML_DIR}/version.json"

echo "[entrypoint] Generating index.html from template..."
envsubst '${APP_VERSION} ${BUILD_SHA} ${ENV_NAME} ${BUILD_DATE}' \
  < "${TEMPLATE}" \
  > "${OUTPUT}"

echo "[entrypoint] Writing version.json..."
cat > "${VERSION_JSON}" <<EOF
{
  "version":   "${APP_VERSION}",
  "sha":       "${BUILD_SHA}",
  "env":       "${ENV_NAME}",
  "buildDate": "${BUILD_DATE}"
}
EOF

echo "[entrypoint] Starting nginx..."
exec nginx -g 'daemon off;'
