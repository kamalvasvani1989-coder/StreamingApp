# ---------- Stage 1: install production dependencies ----------
# Build tools (python3/make/g++) are only needed if a native module such as bcrypt
# must be compiled. They stay in this stage and never reach the final image.
FROM node:22-alpine AS deps
WORKDIR /app
RUN apk add --no-cache python3 make g++
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# ---------- Stage 2: runtime ----------
FROM node:22-alpine
ENV NODE_ENV=production \
    PORT=3004
WORKDIR /app
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node . .

# Run as the unprivileged 'node' user that ships with the official image
USER node
EXPOSE 3004
CMD ["node", "index.js"]
