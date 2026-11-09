# Deploy

The Ledger production stack in one `docker-compose.yml`: the Vue SPA behind nginx, the .NET API with
its one-shot migration, and PostgreSQL. It follows the layout of Cloche's deploy without identity,
logs and backups. TLS and the public ports belong to the shared proxy in
[`../../Cloche/edge`](../../Cloche/edge/README.md) (`sites/ledger.caddy`), a separate compose project.

```bash
cd deploy
cp .env.example .env && chmod 600 .env             # domain, registry, database password
cp .app.env.example .app.env && chmod 600 .app.env # the API's own configuration
./scripts/deploy.sh
```

| Script | What it does |
|--------|--------------|
| `scripts/deploy.sh [tag] [service=tag ...]` | Creates the shared `ledger_edge` network if missing, pulls the images, applies migrations, (re)starts everything. Run on every release. A bare tag moves both application images, `api=`/`web=` just one. |

## What runs

```
                 :80 / :443
                     │
            edge/caddy ── TLS, HTTP→HTTPS          (separate project, ../../Cloche/edge)
                     │  ledger_edge
        <DOMAIN>, app.<DOMAIN>
                     │
                web (nginx) ── /api/, /health/ ──► api ── postgres
                                                  ▲
                                    migrate ──────┘ (one-shot, before api)
```

| Service | Image | Notes |
|---------|-------|-------|
| `web` | `<REGISTRY>/ledger-web` | nginx: the SPA on every host name, `/api/` and `/health/` proxied to `api`. Joins `ledger_edge` under the alias `ledger-web`, which is what `sites/ledger.caddy` proxies to. |
| `migrate` | `<REGISTRY>/ledger-api` | `dotnet Ledger.Host.dll migrate`; must exit 0 before `api` starts. |
| `api` | `<REGISTRY>/ledger-api` | The API on 8080, inside the `app` network only. Also runs the outbox and scheduler workers, so it stays a single replica. |
| `postgres` | `postgres:17-alpine` | The application database, volume `postgres_data`. |

Two networks: `edge` (the external `ledger_edge`, shared with the edge proxy; only `web` is on it)
and `app` (web, API, database). No service publishes a port.

## Configuration

`.env` — read by compose itself:

| Variable | Notes |
|----------|-------|
| `DOMAIN` | Must equal `LEDGER_DOMAIN` in the edge project's `.env`. Feeds the API's CORS origins. |
| `REGISTRY` | Where `ledger-api` and `ledger-web` live, e.g. a Docker Hub user. |
| `LEDGER_TAG`, `LEDGER_API_TAG`, `LEDGER_WEB_TAG` | Image tags; `deploy.sh` overrides them from its arguments. |
| `POSTGRES_IMAGE`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | The database; compose builds `ConnectionStrings__Ledger` from them. The password is not in the connection string but in `PGPASSWORD`, which Npgsql reads itself, so a password with `;`, `=` or quotes needs no escaping. `GSS Encryption Mode=Disable` stops Npgsql probing for Kerberos, which the image lacks (`Cannot load library libgssapi_krb5.so.2`). |

`POSTGRES_PASSWORD` is applied by the `postgres` image **only when the `postgres_data` volume is
empty**. Changing it in `.env` afterwards does not change the database's password, and `migrate`
fails with `28P01: password authentication failed`. Change it inside the database too:

```bash
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "ALTER USER \"$POSTGRES_USER\" PASSWORD '<the new password>'"
```

`.app.env` — passed to `migrate` and `api` as is: `Authentication__Authority`,
`Authentication__Audience` (the JWT issuer and audience the API validates), `Ledger__BaseCommodity`.

## nginx

`nginx/templates` is mounted over the image's `/etc/nginx/templates`; the official nginx entrypoint
renders it into `conf.d` on start. `NGINX_ENVSUBST_FILTER=^LEDGER_` keeps envsubst from touching
nginx's own `$variables`. `api:8080` is resolved through Docker's DNS at request time (`resolver`
plus a variable in `proxy_pass`), so nginx starts and survives an API restart without a reload.
Security headers are repeated inside `location /assets/` because `add_header` there replaces, not
extends, the server-level set.

## Images

- `ledger-api` — `../api/Dockerfile`, published by `api/.github/workflows/docker.yml` after a green
  CI run on `main`.
- `ledger-web` — `../web/Dockerfile` (`npm run build`, then `nginx:alpine` with the `dist`), published
  by `web/.github/workflows/docker.yml` on every push to `main`.

Both are pushed to `<DOCKERHUB_USERNAME>/ledger-*` as `latest` and `sha-<7>` after a Trivy scan
(CRITICAL/HIGH with a fix available fails the build), with an SBOM, provenance and a keyless cosign
signature. Each repository needs the secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`; `REGISTRY` in
`.env` is then the same Docker Hub user, and `./scripts/deploy.sh sha-1a2b3c4` deploys one commit.

By hand:

```bash
docker build -t $REGISTRY/ledger-api:latest ../api && docker push $REGISTRY/ledger-api:latest
docker build -t $REGISTRY/ledger-web:latest ../web && docker push $REGISTRY/ledger-web:latest
```

## Local development

`docker-compose.dev.yml` is the local database for `dotnet run` (port 5432 on loopback, the
credentials of `appsettings.Development.json`):

```bash
docker compose -f docker-compose.dev.yml up -d
```

## Before you go live

- `POSTGRES_PASSWORD` set and stored in a password manager.
- `Authentication__Authority` and `Authentication__Audience` set: outside Development every `/api`
  call requires a bearer token.
- Never `docker compose down -v` on the server: it deletes the database.
