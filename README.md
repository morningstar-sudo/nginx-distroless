# nginx-distroless

Base image: statically compiled nginx + ModSecurity v3 (OWASP CRS) on a
distroless runtime (`cgr.dev/chainguard/static`). No shell, no package
manager, non-root (uid 65532), read-only-filesystem friendly.

- All sources (nginx, ModSecurity, ModSecurity-nginx, CRS, zlib, pcre2,
  libxml2, yajl) are cloned from GitHub at build time. By default the newest
  stable tag is resolved automatically; pin with `--build-arg`.
- ModSecurity is compiled statically into the nginx binary. The WAF is
  toggled at runtime with the env var `IS_MS_ON=true` — a tiny static
  entrypoint selects `nginx-ms.conf` (WAF on) or `nginx.conf` (WAF off).

## Build

```sh
docker build -t nginx-distroless .

# pin versions instead of latest:
docker build -t nginx-distroless \
  --build-arg NGINX_TAG=release-1.28.0 \
  --build-arg MODSEC_TAG=v3.0.14 \
  --build-arg CRS_TAG=v4.16.0 .
```

Note: default `latest` resolves tags at build time, so builds are not
bit-for-bit reproducible and a cached layer can keep an old version — use
`--no-cache` or pinned tags when that matters. Resolved versions are printed
in the build log (`nginx=...`, `modsecurity=...`).

## Run

```sh
# WAF off
docker run --rm -p 8080:8080 --read-only --tmpfs /tmp nginx-distroless

# WAF on (OWASP CRS)
docker run --rm -p 8080:8080 --read-only --tmpfs /tmp \
  -e IS_MS_ON=true nginx-distroless
```

Listens on **8080** (non-root cannot bind 80). No TLS — terminate at your
LB/ingress.

## Using as a base image

Extension points — copy files in, never modify the base:

```dockerfile
FROM ghcr.io/<owner>/nginx-distroless:latest

# replace/extend server blocks (included at http level)
COPY my-site.conf /etc/nginx/conf.d/default.conf

# your static content
COPY dist/ /usr/share/nginx/html/

# optional: custom ModSecurity rules/exclusions, evaluated after CRS
COPY my-rules.conf /etc/nginx/modsecurity.d/
```

To disable a CRS rule that false-positives on your site, add to
`/etc/nginx/modsecurity.d/*.conf`:

```
SecRuleRemoveById 942100
```

## Kubernetes

```yaml
containers:
  - name: web
    image: ghcr.io/<owner>/nginx-distroless:latest
    ports: [{ containerPort: 8080 }]
    env:
      - { name: IS_MS_ON, value: "true" }
    securityContext:
      runAsNonRoot: true
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      capabilities: { drop: [ALL] }
    volumeMounts:
      - { name: tmp, mountPath: /tmp }
volumes:
  - { name: tmp, emptyDir: {} }
```

## CI

`.github/workflows/build.yml` uses `abxst/actions/strict@v3`: build → Trivy
scan (strict gate, all severities block) → push to `ghcr.io` on `main`.
PRs only build + scan.

## Verify

```sh
curl -i localhost:8080/                                  # 200
curl -i "localhost:8080/?q=<script>alert(1)</script>"    # 403 with IS_MS_ON=true, 200 without
docker run --rm --entrypoint /bin/sh nginx-distroless    # must fail: no shell
```
