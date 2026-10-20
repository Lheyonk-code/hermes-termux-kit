# hermes-termux-kit

Satu perintah untuk memasang **Hermes Agent di Termux/Android** — lahir dari
rebuild nyata (bukan teori), jadi tidak ada yang perlu mengulang berjam-jam.

```bash
pkg install -y git
git clone https://github.com/robbertcalliso-code/hermes-termux-kit
cd hermes-termux-kit
bash install.sh
```

Selesai. Hermes langsung bisa dipakai (`hermes -z "halo"`).

## Yang dikerjakan `install.sh`

1. **Prerequisites** — git, curl, gnupg (auto `pkg install` kalau kurang)
2. **Binary Hermes** — repo APT resmi Nous Research, **fingerprint PGP diverifikasi
   dulu** (salah fingerprint = berhenti, bukan lanjut diam-diam).
   Probe otomatis channel `stable` → `canary` (`stable` sering 404).
   Di Linux non-Termux, jatuh ke installer resmi.
3. **Config + `.env`** — `~/.hermes` dibuat mode 700, `.env` mode 600
4. **Provider chain** — `providers.yaml` + **semua key dipindah ke `.env`**
   (nol plaintext tersebar di repo/file config)
5. **Service autostart** (runsv) — `hermes-serve`, `jb-injector` (opsional),
   `hermes-maintain`
6. **Auto-rotate + cek sehat berkala** — cron `every 6h` + service runsv
7. **Health check + smoke test** — provider benar-benar diuji `--chat`, lalu `hermes -z`

Tanpa Tor, tanpa proxy — jalur langsung.

## Auto-rotate & cek sehat

`health_check.py` tidak berhenti di "koneksi hidup". Dia:
- resolusi key dari `~/.hermes/.env`
- `GET /models` → endpoint hidup + key diterima
- `POST /chat/completions` (`--chat`) → benar-benar bisa dipakai
- cek mode `.env`, config, status service runsv
- `--smoke` → uji `hermes -z` end-to-end
- `--json` → keluaran mesin (untuk cron/monitoring), `exit 0` = sehat

`rotate_keys.py` dua tugas terpisah:
- `--env-only` — tarik key literal nyasar ke `~/.hermes/.env` (idempoten, tanpa jaringan)
- `--rotate` — rotasi di provider **hanya kalau endpoint rotasinya benar-benar
  diketahui**. Kalau tidak ada, script **tidak mengarang key** — dia bilang
  "rotate manual di dashboard". Kejujuran > terlihat otomatis.
- `--scrub` — bersihkan key lama dari file/DB (`state.db`) setelah rotasi

`hermes-maintain.sh` menggabungkan keduanya + ringkasan ke `~/logs/hermes-maintain.log`.
**Watchdog:** stdout kosong = sehat (tidak mengirim apa pun); ada alarm = masalah.

## Jalan juga tanpa `termux-services`

Auto-rotate + cek sehat punya **dua jalur**: service runsv (tahan restart HP) dan
cron Hermes (`hermes cron create "every 6h" --name hermes-maintain --script
hermes-maintain.sh --no-agent`). Salah satu tidak tersedia, yang lain jalan.

> Cron menolak symlink & path di luar `~/.hermes/scripts/` — `install.sh` menaruh
> **salinan nyata** di sana, bukan link.

## Opsi

```
bash install.sh --no-services     # tanpa runsv service
bash install.sh --no-injector     # tanpa jb-injector
bash install.sh --canary|--stable # paksa channel APT
bash install.sh --dry-run         # tunjukkan langkahnya saja
bash update.sh                    # tarik pembaruan repo (config hidup tidak tersentuh)
```

## Update aman

`git pull` di repo ini **tidak pernah menyentuh** `~/.hermes` (config, `.env`,
memories, sessions) — semuanya di luar repo. `update.sh` juga mengulang health
check setelah pull.

## Kredensial

Semua key hidup di `~/.hermes/.env` (chmod 600) dan dirujuk sebagai `${NAMA_VAR}`
di `providers.yaml`. `providers.yaml` di repo ini **nol key literal** — verifikasi
otomatis di akhir `rotate_keys.py --env-only`.

## Catatan jujur (bukan klaim berlebihan)

- **Verifikasi PGP** hanya jalan di Termux (repo APT upstream menolak Termux;
  installer resmi dipakai di Linux).
- **`--rotate`** bergantung provider. `river` tidak punya endpoint rotasi publik
  → jalur manual di dashboard. Ini kondisi provider, bukan bug kit.
- **Cron butuh gateway hidup** untuk menyala sendiri. Tanpa gateway, job tetap
  tersimpan dan bisa dipicu manual (`hermes cron run <job_id>`).
- **`health_check.py` dikenal-samar**: provider berstatus `blocked` /
  `blocked_ip_403` dihitung sebagai *kondisi diketahui* (IP mobile diblok), bukan
  kegagalan baru — supaya exit code tidak merah terus tiap 6 jam.

## Lisensi

MIT.
