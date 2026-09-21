# M6: Vendor stage — download xterm.js and Monaco editor so the IDE works
# in network-isolated environments. Images are built on an internet-connected
# machine once; the resulting Docker image has no CDN dependency at runtime.
FROM node:20-alpine AS vendor-js
WORKDIR /vendor
RUN npm install \
    xterm@5.3.0 \
    xterm-addon-fit@0.8.0 \
    monaco-editor@0.52.0 \
    && echo "Vendor download complete"

# ── Final nginx image ──────────────────────────────────────────────────────
FROM nginx:alpine
RUN apk add --no-cache netcat-openbsd

# Copy vendored client-side libraries into the webroot under /vendor/.
# The frontend's index.html references these paths instead of cdn.jsdelivr.net.
COPY --from=vendor-js /vendor/node_modules/xterm/css/xterm.css          /usr/share/nginx/html/vendor/xterm.css
COPY --from=vendor-js /vendor/node_modules/xterm/lib/xterm.js            /usr/share/nginx/html/vendor/xterm.js
COPY --from=vendor-js /vendor/node_modules/xterm-addon-fit/lib/xterm-addon-fit.js \
                                                                          /usr/share/nginx/html/vendor/xterm-addon-fit.js
COPY --from=vendor-js /vendor/node_modules/monaco-editor/min/vs          /usr/share/nginx/html/vendor/vs

COPY wait-for-backends.sh /wait-for-backends.sh
COPY nginx.conf /etc/nginx/conf.d/default.conf
RUN chmod +x /wait-for-backends.sh
ENTRYPOINT ["/wait-for-backends.sh"]
CMD ["nginx", "-g", "daemon off;"]
