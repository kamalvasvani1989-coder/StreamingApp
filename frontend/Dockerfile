# ---------- Stage 1: build the React app ----------
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .

# API URLs are baked in at build time. Defaults are RELATIVE paths, so the same
# image works behind any hostname: the ALB Ingress routes /api/* to the backends.
ARG REACT_APP_AUTH_API_URL=/api
ARG REACT_APP_STREAMING_API_URL=/api
ARG REACT_APP_STREAMING_PUBLIC_URL=/
ARG REACT_APP_ADMIN_API_URL=/api/admin
ARG REACT_APP_CHAT_API_URL=/api/chat
ARG REACT_APP_CHAT_SOCKET_URL=/
ENV REACT_APP_AUTH_API_URL=$REACT_APP_AUTH_API_URL \
    REACT_APP_STREAMING_API_URL=$REACT_APP_STREAMING_API_URL \
    REACT_APP_STREAMING_PUBLIC_URL=$REACT_APP_STREAMING_PUBLIC_URL \
    REACT_APP_ADMIN_API_URL=$REACT_APP_ADMIN_API_URL \
    REACT_APP_CHAT_API_URL=$REACT_APP_CHAT_API_URL \
    REACT_APP_CHAT_SOCKET_URL=$REACT_APP_CHAT_SOCKET_URL \
    CI=false \
    GENERATE_SOURCEMAP=false
RUN npm run build

# ---------- Stage 2: serve with unprivileged nginx (non-root, port 8080) ----------
FROM nginxinc/nginx-unprivileged:1.28-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build /usr/share/nginx/html
EXPOSE 8080
