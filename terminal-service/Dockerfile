# Stage 1: grab just the docker CLI binary
FROM docker:27-cli AS docker-cli

# Stage 2: Node.js service
FROM node:20-slim

# Build deps for node-pty (native module)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

# Copy docker CLI from stage 1
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker

WORKDIR /app
COPY package.json .
RUN npm install
COPY src/ ./src/

EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/health', r => process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

CMD ["node", "--max-old-space-size=3072", "src/index.js"]
