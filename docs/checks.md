# Ověření po nasazení

Samotné spuštění kontejnerů ochranu nedokazuje. Po `post-deploy.sh` v kontejneru projdi tyto kontroly. Dokud není hotová cesta HAProxy, bod 1 ukáže lokálního klienta, ne internetovou adresu.

1. V `access.log` Traefiku ověř první pole řádku. V režimu `local` to má být TCP peer zkoušky. Po zapnutí `haproxy` to má být adresa z PROXY hlavičky.
2. Pošli požadavek s podvrženým `X-Forwarded-For`. V logu musí zůstat peer z předchozího bodu.
3. `docker exec lu-crowdsec cscli metrics` má u parseru Traefiku ukazovat přečtené řádky, ne trvalé chyby parsování.
4. `docker exec lu-crowdsec cscli decisions add --ip ZKUŠEBNÍ-IP -d 2m` a nový požadavek z této IP má Traefik odmítnout. Po zkoušce rozhodnutí smaž. Společná adresa VPS se tímto postupem nesmí stát banem pro všechny klienty.
5. Požadavek s `Host: ludek.serveftp.org` musí dojít do tohoto Nextcloudu. Cizí SNI nebo Host nesmí otevřít data tohoto stacku.
6. V režimu `local` Traefik používá výchozí certifikát. HTTP-01 se ověřuje až po průchodu veřejného portu 80 na entrypoint `web`.
7. `PROPFIND` na WebDAV s heslem aplikace Nextcloudu musí projít bez BasicAuth Traefiku.
8. Velký upload ověř až po úpravě timeoutu HAProxy. Limit Traefiku je 16G a `readTimeout` na `websecure` je `0s`.
9. Dashboard a Metabase na veřejném portu 443 pro `ludek.serveftp.org` nemají odpovídat. Patří na entrypoint `admin` a vyžadují whitelist i BasicAuth. Metabase potom ještě vlastní heslo.
10. `ss` nebo `docker ps` na hostiteli kontejneru nemá ukazovat publikované porty 5432, 6379, 9000 ani 3000.
11. Healthcheck Metabase ověřuje jen otevřený port 3000 uvnitř kontejneru. Odpověď `/api/health` ověř zvlášť z kontejneru v síti `lu-proxy`.

Statická kontrola před prvním spuštěním je `./scripts/test.sh --static`. Po vykreslení stacku, stále bez startu nových služeb, lze spustit:

```bash
cd /docker-data/stacks/infrastructure-nextcloud-lu
docker compose --env-file .env config
```
