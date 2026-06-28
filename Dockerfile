FROM node:22-alpine AS builder

WORKDIR /app

COPY app/package*.json ./
RUN npm ci --omit=dev

COPY app/src/ ./src/

FROM node:22-alpine

RUN apk upgrade --no-cache && \
    addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/src ./src
COPY --from=builder /app/package.json ./

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "src/index.js"]
