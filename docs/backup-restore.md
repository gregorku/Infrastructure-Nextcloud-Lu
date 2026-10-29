# Záloha a obnova

## Záloha

`./scripts/backup.sh` běží jako root v kontejneru po úspěšném nasazení.

1. Zapne maintenance mode Nextcloudu.
2. Udělá `pg_dump -Fc` databáze Nextcloudu i Metabase.
3. Ověří, že oba dumpy začínají hlavičkou `PGDMP`.
4. Přidá `config`, `custom_apps` a `themes` z HTML stromu.
5. Zveřejní tar až po této kontrole. Zdrojová data nemaže.
6. Maintenance mode zase vypne.

Tar neobsahuje soubory uživatelů. Ty leží v `NEXTCLOUD_DATA_HOST_DIR`. Když je na kontejneru `restic` a `RESTIC_REPOSITORY`, skript přidá snapshot tohoto adresáře. `restic forget` se nespouští automaticky.

`BACKUP_AGE_RECIPIENT` je veřejný příjemce `age`. Soukromý klíč do `.env` nepatří. Prázdný příjemce šifrovanou kopii nevytváří.

## Obnova

Obnova nejdřív nic živého nemění:

```bash
./scripts/restore.sh \
  --archive /docker-data/backups/infrastructure-nextcloud-lu/infrastructure-nextcloud-lu-STAMP.tar \
  --confirm infrastructure-nextcloud-lu
```

Příkaz rozbalí archiv do dočasného adresáře, zkontroluje oba dumpy a skončí kódem 2. Šifrovaný archiv potřebuje `--identity` už v tomto kroku. Bez platného archivu se k živým datům nesáhne.

Teprve druhý běh se `--replace-data` zastaví Nextcloud a cron, obnoví obě databáze a zkopíruje `config`. Uživatelské soubory ani adresáře PostgreSQL tímto příkazem nemaže. Po obnově databáze zůstanou Nextcloud a cron zastavené, aby šly před startem zkontrolovat.

Snapshot Restic se tímto skriptem neobnovuje. Obnova souborů uživatelů má mít vlastní, předem ověřený příkaz `restic restore` do prázdného cíle, ne do živého adresáře.
