# Architektura

## Dva vstupy

V domácím kontejneru stack poslouchá na Traefiku. Lokální zkouška používá `PROXY_PROTOCOL_MODE=local` a `TRAEFIK_TLS_MODE=local`. Traefik v tomto režimu nečeká PROXY hlavičku a používá svůj výchozí certifikát.

Veřejný a funkční vstup Nextcloudu je na portech 80 a 443. PROXY protocol patří jen sem:

```text
Internet
  -> DNS ludek.serveftp.net na veřejnou adresu VPS
  -> HAProxy na VPS, send-proxy-v2
  -> existující WireGuard
  -> Traefik entrypointy web :80 a websecure :443
  -> Nginx
  -> Nextcloud FPM
```

Tento repozitář nezapisuje backend HAProxy, peer WireGuardu, firewall ani DNAT této cesty. `10.10.10.10` je Traefik na VPS a do tohoto stacku nepatří.

Metabase je dostupná jen přes WireGuard. Nejde přes veřejný internet, HAProxy ani porty 80 a 443:

```text
WireGuard klient
  -> VPS
  -> WireGuard
  -> MikroTik, DNAT bez SNAT a bez masquerade
  -> Incus nextcloudLu, 192.168.12.233:8444
  -> Traefik entrypoint metabase :8444
  -> Metabase :3000
```

Přístupová adresa je `https://10.100.100.1:9444`. Entrypoint `metabase` PROXY protocol nepoužívá, takže Traefik vidí TCP peer po DNAT. MikroTik zdrojovou adresu nemění, a proto je tím peerem původní adresa WireGuard klienta. Návratová trasa k této adrese je odpovědnost MikroTiku. Tento repozitář ji nenastavuje a konfiguraci VPS ani MikroTiku nemění.

`METABASE_IP_ALLOWLIST` uvádí jednotlivé důvěryhodné klientské adresy jako `/32`. Celá VPN síť se nepovoluje automaticky. Skutečné adresy v projektu nejsou. Placeholder `set_metabase_allowlist` deploy odmítne.

## Entrypointy

`deploy.sh` vykreslí `runtime/traefik/traefik.yml`:

- `web` na `:80` přesměruje na `websecure`;
- `websecure` na `:443` má `readTimeout: 0s` kvůli velkým uploadům;
- `admin` na `:8443` slouží dashboardu Traefiku;
- `metabase` na `:8444` slouží jen Metabase.

Soubor v Gitu `compose/15-traefik-admin-port.yml` port nezveřejňuje. Po synchronizaci ho `deploy.sh` přepíše jen v adresáři stacku. `TRAEFIK_ADMIN_PUBLISH` smí mít tvar `soukromá-adresa:8443:8443`. Prázdná hodnota port na hostiteli nezveřejní.

## Routery

Veřejný router Nextcloudu platí pro `Host(\`ludek.serveftp.net\`)` na `websecure`. Middleware `nextcloud-chain` obsahuje hlavičky vhodné pro Nextcloud, CrowdSec, limit požadavků a kompresi. BasicAuth na tomto routeru není, aby zůstaly funkční WebDAV, klienti a přihlášení Nextcloudu.

Dashboard Traefiku má entrypoint `admin` a middleware `default-chain`: IP whitelist, bezpečnostní hlavičky, komprese a BasicAuth.

Metabase má entrypoint `metabase` na portu `8444`, hostitelský bind `192.168.12.233:8444`, pravidlo `PathPrefix(/)` a backend `http://metabase:3000`. Přístupová adresa je `https://10.100.100.1:9444`. Před aplikací Traefik vyžaduje `METABASE_IP_ALLOWLIST` a BasicAuth ze souboru `dashboard.htpasswd`. Metabase si potom ponechává vlastní přihlášení. Nemá veřejné DNS jméno a není na routeru Nextcloudu. Allowlist jsou jednotlivé `/32` WireGuard klientů, ne celá VPN.

`TRUSTED_PROXIES` v Nextcloudu musí být CIDR uvnitř `DOCKER_PROXY_SUBNET`. To je síť, ze které Nginx vidí Traefik. Veřejný internet ani rozsah WireGuardu sem nepatří.

## PROXY protocol a forwarded hlavičky

`PROXY_PROTOCOL_MODE=local` blok `proxyProtocol` nevykreslí. Lokální klient může otevřít Traefik bez PROXY hlavičky. V access logu je potom TCP peer, u lokální zkoušky adresa toho klienta. Režim `haproxy` zapisuje `proxyProtocol` jen na entrypointy `web` a `websecure`. Entrypointy `admin` a `metabase` ho nemají.

`PROXY_PROTOCOL_MODE=haproxy` vykreslí `proxyProtocol.trustedIPs` jen jako seznam `/32`. Vyžaduje `TRAEFIK_TLS_MODE=letsencrypt`. `proxyProtocol.insecure` se nezapíná.

`forwardedHeaders.trustedIPs` se nevykresluje. Traefik 3.6.22 nejdřív zahodí `X-Forwarded-*` od nedůvěryhodného TCP peeru a teprve potom zapíše access log. Při prázdném seznamu forwarded hlaviček zůstane v logu adresa z PROXY protokolu. Plugin CrowdSec seznam `forwardedHeadersTrustedIPs` také nemá, takže rozhodnutí bere `RemoteAddr`.

Před zapnutím režimu `haproxy` musí být známá skutečná zdrojová adresa, kterou domácí Traefik uvidí jako TCP peer HAProxy. Širší rozsah nebo `0.0.0.0/0` kontrola prostředí odmítne.

## TLS

`TRAEFIK_TLS_MODE=local` certifikát Let's Encrypt nežádá. `letsencrypt` vykreslí HTTP-01 na entrypointu `web` a e-mail do vygenerovaného YAML, protože statický soubor Traefiku proměnné prostředí nerozbaluje.

Certifikát HTTP-01 vznikne až ve chvíli, kdy veřejný port 80 dorazí přes HAProxy a WireGuard na tento Traefik. Do té doby režim `letsencrypt` certifikát nezíská. DNS-01 se nepoužívá. `acme.json` se zakládá s oprávněním `600` a existující soubor se nezkracuje.

## CrowdSec

CrowdSec má vlastní data v `${DATA_DIR}/crowdsec/data` a čte `/logs/access.log` tohoto Traefiku. Parser dodá kolekce `crowdsecurity/linux` a `crowdsecurity/traefik`, které instaluje `post-deploy.sh`. Bouncer se jmenuje `lu-traefik`. Klíč je v `${DATA_DIR}/traefik/crowdsec/BOUNCER_KEY_lu-traefik`, mimo Git. LAPI je jen na síti `lu-internal`.

Rozhodnutí se nesdílí s CrowdSec na VPS. Instalace kolekcí sama o sobě ochranu nedokazuje. Postup ověření je v [checks.md](checks.md).

## Data

| Účel | Cesta |
| --- | --- |
| HTML Nextcloudu | `/docker-data/infrastructure-nextcloud-lu/html` |
| PostgreSQL Nextcloudu | `POSTGRESQL_HOST_DIR` |
| Soubory uživatelů | `NEXTCLOUD_DATA_HOST_DIR` |
| PostgreSQL Metabase | `/docker-data/infrastructure-nextcloud-lu/metabase/postgres` |
| Data Metabase | `/docker-data/infrastructure-nextcloud-lu/metabase/data` |
| Zálohy | `/docker-data/backups/infrastructure-nextcloud-lu` |

Adresář PostgreSQL Nextcloudu musí ležet mimo Git, stack, HTML, zálohy i adresář PostgreSQL Metabase. Kontrola odmítne i vnoření těchto cest. Prázdný adresář dostane vlastníka `33:33` pro Nextcloud a `999:999` pro PostgreSQL. Neprázdný strom se rekurzivně nemění.

Obraz Nextcloudu je `35.0.2-fpm`, PostgreSQL Nextcloudu `18.6` s `PGDATA=/var/lib/postgresql/18/docker`, PostgreSQL Metabase `17.11` s daty v `/var/lib/postgresql/data`. Bootstrap role `nc_bootstrap` zůstává SUPERUSER. Aplikační role `nextcloud` se zakládá bez oprávnění superuser. Opakovaný deploy Nextcloud nepřeinstalovává.
