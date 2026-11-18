FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=0 GOOS=linux go build -o /plezy-sync-server .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
WORKDIR /data
COPY --from=builder /plezy-sync-server /usr/local/bin/plezy-sync-server
EXPOSE 8088
ENTRYPOINT ["/usr/local/bin/plezy-sync-server", "-addr", ":8088", "-data-dir", "/data"]
