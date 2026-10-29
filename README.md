# Infrastructure-Nextcloud-Lu

Samostatný Docker Compose stack pro Nextcloud na `ludek.serveftp.org` v domácím Incus kontejneru s Debianem 13. Docker, Docker Compose a Dockge už v kontejneru jsou. Skripty je neinstalují, nezastavují a neodstraňují.

Stack se má nejdřív spustit a ověřit uvnitř kontejneru. Cesta z internetu přes HAProxy a WireGuard se doplní později, až bude známá cílová adresa a port.

## Pořadí skriptů

Skripty se spouštějí jako root v kontejneru, z checkoutu repozitáře. Očekávaná cesta checkoutu je `/incus-dir/git/Infrastructure-Nextcloud-Lu`.

1. `./scripts/init.sh` vytvoří adresáře projektu a zkopíruje Compose a konfiguraci do `/docker-data/stacks/infrastructure-nextcloud-lu`. Existující Docker sítě a kontejnery nemaže.
2. `./scripts/update-env.sh` vytvoří nebo doplní runtime `.env`. Vygenerovaná hesla se do terminálu nevypisují.
3. Doplň hodnoty `set_` podle [docs/operations.md](docs/operations.md).
4. `./scripts/create-dashboard-user.sh` zapíše BasicAuth pro administraci.
5. `./scripts/check-env.sh` ověří povinné hodnoty.
6. `./scripts/deploy.sh` vykreslí runtime konfiguraci a spustí Compose. Volume a data nemaže.
7. `./scripts/post-deploy.sh` nainstaluje kolekce CrowdSec, vytvoří bouncer klíč, pokud ještě není, a zapíše nainstalovanou verzi Nextcloudu.

`./scripts/test.sh --static` lze spustit i mimo kontejner. Kontejnery nespouští.

`/docker-data` musí být existující mountpoint Incus disku. Skript ho nevytváří na kořenovém souborovém systému.

## Služby

| Kontejner | Účel | Publikovaný port |
| --- | --- | --- |
| `lu-traefik` | HTTP, HTTPS a administrace | `80` a `443`; `8443` jen při explicitním soukromém bindu |
| `lu-crowdsec` | LAPI a rozhodnutí | žádný |
| `lu-nginx` | HTTP před PHP-FPM | žádný |
| `lu-nextcloud` | Nextcloud FPM | žádný |
| `lu-cron` | cron Nextcloudu | žádný |
| `lu-postgresql` | databáze Nextcloudu | žádný |
| `lu-redis` | cache a zámky | žádný |
| `lu-metabase` | Metabase | žádný |
| `lu-metabase-postgresql` | databáze Metabase | žádný |

Sítě `lu-proxy` a `lu-internal` jsou externí a patří jen tomuto stacku. PostgreSQL, Redis, PHP-FPM a Metabase mezi sebou mluví po `lu-internal`. Traefik dosáhne na Nginx a Metabase po `lu-proxy`.

Další popis je v [docs/architecture.md](docs/architecture.md), provoz v [docs/operations.md](docs/operations.md), zálohy v [docs/backup-restore.md](docs/backup-restore.md) a ověření v [docs/checks.md](docs/checks.md).
