# Stage 1: Build embedded React Web UI
FROM node:22-alpine AS web-builder
WORKDIR /app/web
COPY web/package*.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# Stage 2: Build pure-Go static binary (without embedding web assets)
FROM golang:1.26-alpine AS go-builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/media-library ./cmd/media-library

# Stage 3: Minimal runtime image
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /data
COPY --from=go-builder /out/media-library /usr/local/bin/media-library
COPY --from=web-builder /app/web/dist /usr/local/bin/web/dist
VOLUME ["/data"]
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/media-library"]
CMD ["-addr", "0.0.0.0:8090", "-data-dir", "/data"]
