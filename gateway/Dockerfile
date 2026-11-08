# Static binary, so the final image needs no Go toolchain and no libc.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /gateway .

FROM alpine:3.21
# Supabase and the Anthropic API are HTTPS, so the image needs CA roots.
RUN apk add --no-cache ca-certificates && adduser -D -u 10001 syncgw
COPY --from=build /gateway /usr/local/bin/gateway
USER syncgw
EXPOSE 8787
# Media lives in Supabase Storage; /tmp only holds uploads while they are checked.
ENTRYPOINT ["/usr/local/bin/gateway", "-addr", ":8787", "-data", "/tmp/sync", "-client-ip-header", "Fly-Client-IP"]
