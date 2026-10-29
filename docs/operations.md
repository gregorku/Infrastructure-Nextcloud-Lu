# Provoz

## Hodnoty před prvním nasazením

`check-env.sh` odmítne hodnotu začínající `set_`. Před `deploy.sh` musí být vyplněno:

- `POSTGRESQL_HOST_DIR` a `NEXTCLOUD_DATA_HOST_DIR`, dvě různé ne-vnořené absolutní cesty na disku `/docker-data`;
- `DOCKER_PROXY_SUBNET`, `DOCKER_PROXY_GATEWAY`, `DOCKER_INTERNAL_SUBNET`, `DOCKER_INTERNAL_GATEWAY`, soukromé rozsahy s prefixem 16–28, které se nepřekrývají mezi sebou ani s existující Docker sítí;
- `TRUSTED_PROXIES`, alespoň jeden CIDR ležící uvnitř `DOCKER_PROXY_SUBNET`;
- `ADMIN_IP_ALLOWLIST`, soukromé CIDR administrátorů;
- `METABASE_HOST` a `METABASE_SITE_URL` na `https://` tohoto hostitele;
- hesla, která `update-env.sh` vygeneruje, pokud v runtime `.env` ještě nejsou.

`TRAEFIK_ACME_EMAIL` smí zůstat `set_acme_email` jen v režimu `TRAEFIK_TLS_MODE=local`. Pro `letsencrypt` musí být skutečný e-mail.

`PROXY_PROTOCOL_TRUSTED_IPS` zůstává prázdné, dokud je režim `local`. Do režimu `haproxy` patří jen ověřené zdrojové adresy ve tvaru `/32` a zároveň `TRAEFIK_TLS_MODE=letsencrypt`.

`TRAEFIK_ADMIN_PUBLISH` zůstává prázdné, dokud není vybraná soukromá adresa kontejneru. Hodnota `0.0.0.0:8443:8443` je odmítnuta.

## Co deploy dělá

`deploy.sh` synchronizuje `compose.yml`, `compose/`, `configs/` a `.env.example`. `rsync --delete` běží jen uvnitř těchto zkopírovaných adresářů. Persistentní data, sítě a kontejnery nemaže.

Potom:

- odmítne deploy, když se `NEXTCLOUD_TAG` liší od `state/installed-version`;
- založí chybějící sítě `lu-proxy` a `lu-internal`, a existující síť se stejným jménem a jiným rozsahem ponechá beze změny a skončí chybou;
- vykreslí Traefik, whitelist, router Nextcloudu, router Metabase, `real-ip.conf` a `redis.conf`;
- ověří, že kontejner `dockge` běží a má `DOCKGE_STACKS_DIR=/docker-data/stacks`;
- spustí `docker compose up -d` bez mazání volume;
- založí aplikační roli PostgreSQL, pokud chybí.

`post-deploy.sh` existující bouncer klíč nepřepisuje. Nový klíč se do logu nevypisuje. Verzi zapíše, až `occ status` hlásí nainstalovanou aplikaci se stejnou řadou, jako je pin.

## Upgrade

1. Změň `NEXTCLOUD_TAG` v `.env.example` na přesný tag `X.Y.Z-fpm`.
2. Spusť `./scripts/update-env.sh`.
3. Spusť `./scripts/upgrade.sh --confirm infrastructure-nextcloud-lu`.

Upgrade vyžaduje alespoň `UPGRADE_MIN_FREE_MB` volného místa, zapíše zámek a data nemaže. Při chybě `occ upgrade` zámek zůstane. Běžný `deploy.sh` ho odmítne odstranit.

## HAProxy, který se doplní později

Než se provoz pustí z internetu, musí být rozhodnuto:

- cílová adresa domácího Traefiku dosažitelná z VPS přes stávající WireGuard;
- porty pro HTTP a HTTPS na této adrese;
- TCP adresa, kterou Traefik uvidí jako zdroj HAProxy, zapsaná do `PROXY_PROTOCOL_TRUSTED_IPS`;
- úprava HAProxy tak, aby `ludek.serveftp.org` nepadal do výchozího backendu Gregora Nextcloudu;
- průchod portu 80 až na entrypoint `web`, jinak HTTP-01 certifikát nevznikne;
- timeout HAProxy pro uploady 16G. Výchozí timeout 50 s na VPS umí velký upload přerušit i při `readTimeout: 0s` na Traefiku.

Tyto změny jsou mimo tento repozitář a patří do samostatné kontroly NixOS, HAProxy a WireGuardu.

## Statická kontrola

`./scripts/test.sh --static` kontroluje syntaxi shellu, zakázané vzory a pomocné funkce pro CIDR a cesty. `docker compose config` se při psaní projektu na pracovní stanici nespouštěl, protože Docker Compose tam není.

Až bude v kontejneru vykreslený stack, kontrola bez startu služeb je:

```bash
cd /docker-data/stacks/infrastructure-nextcloud-lu
docker compose --env-file .env config
```
