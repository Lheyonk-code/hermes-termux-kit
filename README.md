# hermes-termux-kit

Satu perintah untuk memasang **Hermes Agent di Termux/Android** — lahir dari
rebuild nyata (bukan teori), jadi tidak ada yang perlu mengulang berjam-jam.

```bash
pkg install -y git
git clone https://github.com/robbertcalliso-code/hermes-termux-kit
cd hermes-termux-kit
bash install.sh
```

**Urutannya sekarang: provider + API key dulu, baru install.** Saat pertama
dijalankan, `install.sh` membuka **wizard interaktif** (Langkah 0) untuk mengisi
provider dan key — minimal 1 provider, boleh tambah beberapa (dipakai untuk
auto-rotate). Setelah kredensial siap, install berjalan sekali jalan sampai
health check + smoke test.

## Langkah 0 — provider + API key dulu

Sebelum menyentuh prerequisites/binary, `install.sh` mengecek
`~/.hermes/providers.yaml` + `~/.hermes/.env`:

- **Belum ada key provider yang terisi** → wizard interaktif berjalan:
  per provider ditanya **nama, base_url, default_model (boleh kosong), dan
  API key**. Key ditulis **HANYA** ke `~/.hermes/.env` (chmod 600, input
  disembunyikan); `providers.yaml` memakai referensi `"${NAMA_ENV}"` — nol
  key plaintext di file config. Setelah provider pertama, ditawari tambah
  provider lagi (2, 3, ... sesuai jumlah yang diisi — chain untuk auto-rotate).
- **Sudah terisi** → Langkah 0 dilewati. **Idempoten**: install ulang /
  `git pull` + `bash install.sh` lagi **tidak pernah menimpa** kredensial yang
  sudah ada (nilai lama di `.env` dipertahankan; `providers.yaml` lama
  dicadangkan ke `.bak.<tanggal>` sebelum ditulis ulang).

## Yang dikerjakan `install.sh`

0. **Langkah 0 — provider + API key** — wizard interaktif kalau belum terisi
   (lihat di atas); dilewati kalau sudah
1. **Prerequisites** — git, curl, gnupg (auto `pkg install` kalau kurang)
2. **Binary Hermes** — repo APT resmi Nous Research, **fingerprint PGP diverifikasi
   dulu** (salah fingerprint = berhenti, bukan lanjut diam-diam).
   Probe otomatis channel `stable` → `canary` (`stable` sering 404).
   Di Linux non-Termux, jatuh ke installer resmi.
3. **Config + `.env`** — `~/.hermes` dibuat mode 700, `.env` mode 600
4. **Provider chain** — `providers.yaml` + **semua key dipindah ke `.env`**
   (nol plaintext tersebar di repo/file config)
5. **Service autostart** (runsv) — `hermes-serve`, `injector` (opsional, `:20129`),
   `hermes-maintain`
7. **Auto-rotate + cek sehat berkala** — cron `every 6h` + service runsv
8. **Health check + smoke test** — provider benar-benar diuji `--chat`, lalu `hermes -z`

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

## `injector.py` — satu pintu ke provider chain

`hermes serve` menangani chat Hermes sendiri. `tools/injector.py` dipakai kalau
kamu butuh **proxy OpenAI-compatible di `:20129`** yang bisa dipakai klien lain —
atau mau menguji provider chain tanpa mengganggu sesi Hermes:

```bash
python3 tools/injector.py serve                 # service di http://127.0.0.1:20129/v1
python3 tools/injector.py chat -m "halo"         # satu prompt lewat chain
python3 tools/injector.py providers              # daftar chain + prioritas
python3 tools/injector.py env-check              # cek resolusi ${VAR} dari ~/.hermes/.env
python3 tools/injector.py health                 # GET /models tiap provider (exit 1 kalau mati semua)
```

Tiga hal yang dia tangani:
- **Key dari `${VAR}`** — literal di `providers.yaml` juga jalan; `${VAR}` diambil
  dari env proses lalu `~/.hermes/.env`.
- **Jatuh ke cadangan** — provider ber-`fallback: true` dipakai kalau yang di
  atasnya gagal, dan `model` diganti ke model milik provider tujuan (bukan
  model provider utama yang kebetulan ikut di-request).
- **Bisa dimonitor** — `GET /health` melaporkan upstream aktif, status tiap
  provider, dan chain-nya (nol dependency, aman untuk cron).

Klien OpenAI mana pun tinggal diarahkan ke `http://127.0.0.1:20129/v1`.
Header `X-Injector-Echo: 1` menyisipkan blok `_injector` (upstream + latensi +
percobaan ke-berapa) di balasan — berguna saat membuktikan failover benar terjadi.

## Jalan juga tanpa `termux-services`

Auto-rotate + cek sehat punya **dua jalur**: service runsv (tahan restart HP) dan
cron Hermes (`hermes cron create "every 6h" --name hermes-maintain --script
hermes-maintain.sh --no-agent`). Salah satu tidak tersedia, yang lain jalan.

> Cron menolak symlink & path di luar `~/.hermes/scripts/` — `install.sh` menaruh
> **salinan nyata** di sana, bukan link.

## Opsi

```
bash install.sh --no-services     # tanpa runsv service
bash install.sh --no-injector     # tanpa injector
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
otomatis di akhir `rotate_keys.py --env-only`. `tools/injector.py env-check`
memeriksa hal yang sama tanpa jaringan: dia bilang provider mana yang `${VAR}`-nya
tidak ketemu, sebelum kamu bingung kenapa request gagal.

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
